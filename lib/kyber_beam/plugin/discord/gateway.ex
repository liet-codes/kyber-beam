defmodule Kyber.Plugin.Discord.Gateway do
  @moduledoc """
  Discord Gateway WebSocket client using Mint.WebSocket.

  Implements a non-blocking state machine for the Discord Gateway lifecycle:
  - :disconnected → :upgrading → :connected

  State transitions:
  1. :connect message → opens Mint.HTTP connection + sends WebSocket upgrade request
  2. TCP messages while :upgrading → accumulate HTTP upgrade response until :done
     → call Mint.WebSocket.new → transition to :connected
     → process any buffered WebSocket data (HELLO may arrive with upgrade response)
  3. TCP messages while :connected → decode WebSocket frames
     → HELLO: start heartbeat + send IDENTIFY
     → READY: store session_id
     → DISPATCH: forward to handler_pid
  4. :heartbeat → send heartbeat frame, reschedule
  5. Error / close → schedule reconnect with exponential backoff

  The handler_pid receives `{:discord_event, json_binary}` messages.
  """

  use GenServer
  require Logger

  @discord_api_base "https://discord.com/api/v10"
  @gateway_path "/?v=10&encoding=json&compress=zlib-stream"
  @gateway_host "gateway.discord.gg"
  @gateway_port 443

  # Discord opcodes
  @op_heartbeat 1
  @op_identify 2
  @op_presence_update 3
  @op_hello 10
  @op_heartbeat_ack 11

  # GUILDS (1) | GUILD_MESSAGES (512) | DIRECT_MESSAGES (4096) | MESSAGE_CONTENT (32768)
  @gateway_intents 37377

  # Zlib flush bytes Discord uses for frame boundaries
  @zlib_suffix <<0x00, 0x00, 0xFF, 0xFF>>

  # Backoff config (ms)
  @backoff_initial 1_000
  @backoff_max 30_000

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc "Send a presence/status update via the Gateway WebSocket."
  @spec send_presence_update(pid(), map()) :: :ok
  def send_presence_update(pid, presence) do
    GenServer.cast(pid, {:presence_update, presence})
  end

  @doc """
  Build an OP 3 STATUS_UPDATE payload.

  ## Keys in presence map
    * `:status` - "online", "idle", "dnd", "invisible" (default: "online")
    * `:game_name` - activity name (optional)
    * `:game_type` - activity type: 0=Playing, 1=Streaming, 2=Listening, 3=Watching, 5=Competing (default: 0)
  """
  @spec build_presence_update(map()) :: map()
  def build_presence_update(presence) do
    status = Map.get(presence, :status, "online")
    game_name = Map.get(presence, :game_name)
    game_type = Map.get(presence, :game_type, 0)

    activities =
      if game_name do
        [%{"name" => game_name, "type" => game_type}]
      else
        []
      end

    %{
      "op" => @op_presence_update,
      "d" => %{
        "since" => nil,
        "activities" => activities,
        "status" => status,
        "afk" => false
      }
    }
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    handler_pid = Keyword.fetch!(opts, :handler_pid)

    state = %{
      token: token,
      handler_pid: handler_pid,
      # Connection state machine: :disconnected | :upgrading | :connected
      status: :disconnected,
      conn: nil,
      websocket: nil,
      ref: nil,
      # Accumulated HTTP upgrade responses
      upgrade_status: nil,
      upgrade_headers: nil,
      # WebSocket data buffered during upgrade phase (Discord sends HELLO immediately)
      buffered_data: [],
      # Sequence and session
      sequence: nil,
      session_id: nil,
      # Heartbeat
      heartbeat_ref: nil,
      heartbeat_interval: nil,
      # Zlib streaming context
      zlib_context: nil,
      # Reconnect backoff
      backoff: @backoff_initial
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    Logger.info("[Discord.Gateway] connecting to #{@gateway_host}...")

    # Clean up old state
    state = cleanup_zlib(state)
    state = cancel_heartbeat(state)

    case start_connection(state.token) do
      {:ok, conn, ref} ->
        # Connection started and upgrade request sent; now wait for HTTP 101 response
        {:noreply, %{state |
          conn: conn,
          ref: ref,
          status: :upgrading,
          upgrade_status: nil,
          upgrade_headers: nil,
          websocket: nil,
          backoff: @backoff_initial
        }}

      {:error, reason} ->
        Logger.error("[Discord.Gateway] connection failed: #{inspect(reason)}, retrying in #{state.backoff}ms")
        Process.send_after(self(), :connect, state.backoff)
        {:noreply, %{state | status: :disconnected, backoff: min(state.backoff * 2, @backoff_max)}}
    end
  end

  def handle_info(:heartbeat, %{status: :connected} = state) do
    payload = Jason.encode!(%{"op" => @op_heartbeat, "d" => state.sequence})

    case send_ws_frame(state, {:text, payload}) do
      {:ok, state} ->
        ref = Process.send_after(self(), :heartbeat, state.heartbeat_interval)
        {:noreply, %{state | heartbeat_ref: ref}}

      {:error, reason, state} ->
        Logger.error("[Discord.Gateway] heartbeat failed: #{inspect(reason)}, reconnecting")
        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(:heartbeat, state) do
    # Not connected — discard stale heartbeat
    {:noreply, state}
  end

  # Handle Mint TCP/SSL messages
  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = process_responses(responses, state)
        {:noreply, state}

      {:error, conn, error, _responses} ->
        Logger.error("[Discord.Gateway] stream error: #{inspect(error)}, reconnecting")
        {:noreply, schedule_reconnect(%{state | conn: conn})}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(_message, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:presence_update, presence}, %{status: :connected} = state) do
    payload = build_presence_update(presence)

    case send_ws_frame(state, {:text, Jason.encode!(payload)}) do
      {:ok, state} -> {:noreply, state}
      {:error, reason, state} ->
        Logger.error("[Discord.Gateway] presence update failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  def handle_cast({:presence_update, _presence}, state) do
    Logger.warning("[Discord.Gateway] cannot update presence: not connected")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_zlib(state)

    if state.conn do
      try do
        Mint.HTTP.close(state.conn)
      rescue
        _ -> :ok
      end
    end

    :ok
  end

  # ── Private: Connection setup ─────────────────────────────────────────────

  defp start_connection(token) do
    gateway_host =
      case fetch_gateway_url(token) do
        {:ok, url} ->
          case URI.parse(url) do
            %URI{host: host} when is_binary(host) and host != "" -> host
            _ -> @gateway_host
          end

        _ ->
          @gateway_host
      end

    Logger.info("[Discord.Gateway] using gateway host: #{gateway_host}")

    case Mint.HTTP.connect(:https, gateway_host, @gateway_port, protocols: [:http1]) do
      {:ok, conn} ->
        case Mint.WebSocket.upgrade(:wss, conn, @gateway_path, []) do
          {:ok, conn, ref} -> {:ok, conn, ref}
          {:error, _conn, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_gateway_url(token) do
    url = "#{@discord_api_base}/gateway/bot"
    headers = [{"Authorization", "Bot #{token}"}]

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} ->
        gateway_url = body["url"] || "wss://#{@gateway_host}"
        Logger.info("[Discord.Gateway] gateway URL: #{gateway_url}")
        {:ok, gateway_url}

      {:ok, %{status: status}} ->
        Logger.warning("[Discord.Gateway] /gateway/bot returned #{status}, using default")
        {:ok, "wss://#{@gateway_host}"}

      {:error, reason} ->
        Logger.warning("[Discord.Gateway] /gateway/bot failed: #{inspect(reason)}, using default")
        {:ok, "wss://#{@gateway_host}"}
    end
  end

  # ── Private: Response processing state machine ────────────────────────────

  defp process_responses(responses, state) do
    Enum.reduce(responses, state, &process_response/2)
  end

  # ── Upgrading phase: accumulate HTTP response ─────────────────────────────

  defp process_response({:status, ref, status}, %{status: :upgrading, ref: ref} = state) do
    %{state | upgrade_status: status}
  end

  defp process_response({:headers, ref, headers}, %{status: :upgrading, ref: ref} = state) do
    %{state | upgrade_headers: headers}
  end

  defp process_response({:done, ref}, %{status: :upgrading, ref: ref} = state) do
    # HTTP upgrade response complete — create WebSocket
    case Mint.WebSocket.new(state.conn, ref, state.upgrade_status, state.upgrade_headers) do
      {:ok, conn, websocket} ->
        Logger.info("[Discord.Gateway] WebSocket established — waiting for HELLO")

        # Initialize zlib inflate context for this session
        z = :zlib.open()
        :zlib.inflateInit(z)

        state = %{state |
          conn: conn,
          websocket: websocket,
          status: :connected,
          zlib_context: z,
          upgrade_status: nil,
          upgrade_headers: nil
        }

        # Drain any buffered WebSocket data that arrived during the upgrade phase.
        # Discord often sends HELLO in the same TCP segment as the HTTP 101 response,
        # arriving as :data responses before :done.
        buffered = Map.get(state, :buffered_data, [])
        state = Enum.reduce(buffered, state, fn data, acc ->
          process_response({:data, ref, data}, acc)
        end)
        %{state | buffered_data: []}

      {:error, _conn, reason} ->
        Logger.error("[Discord.Gateway] WebSocket upgrade failed: #{inspect(reason)}")
        schedule_reconnect(state)
    end
  end

  # ── Connected phase: WebSocket data ───────────────────────────────────────

  defp process_response({:data, ref, data}, %{status: :connected, ref: ref} = state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &handle_ws_frame/2)

      {:error, websocket, reason} ->
        Logger.error("[Discord.Gateway] WebSocket decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  # Buffer :data responses that arrive during the upgrade phase.
  # Discord frequently sends HELLO in the same TCP segment as the HTTP 101,
  # so the binary data arrives before Mint has signalled :done.
  defp process_response({:data, _ref, data}, %{status: :upgrading} = state) do
    Logger.debug("[Discord.Gateway] buffering #{byte_size(data)} bytes of WS data during upgrade")
    buffered = Map.get(state, :buffered_data, [])
    %{state | buffered_data: buffered ++ [data]}
  end

  defp process_response(_response, state), do: state

  # ── Private: WebSocket frame handling ─────────────────────────────────────

  defp handle_ws_frame({:binary, data}, state) do
    # Discord zlib-stream compressed frame
    case inflate_frame(state.zlib_context, data) do
      {:ok, json} -> dispatch_json(json, state)
      {:error, :partial} -> state  # accumulate more data
      {:error, reason} ->
        Logger.error("[Discord.Gateway] zlib error: #{inspect(reason)}")
        state
    end
  end

  defp handle_ws_frame({:text, json}, state) do
    dispatch_json(json, state)
  end

  defp handle_ws_frame({:ping, data}, state) do
    case send_ws_frame(state, {:pong, data}) do
      {:ok, state} -> state
      {:error, _, state} -> state
    end
  end

  defp handle_ws_frame({:close, code, reason}, state) do
    Logger.warning("[Discord.Gateway] server closed: #{code} #{inspect(reason)}")
    schedule_reconnect(state)
  end

  defp handle_ws_frame(_frame, state), do: state

  # ── Private: JSON dispatch ────────────────────────────────────────────────

  defp dispatch_json(json, state) do
    case Jason.decode(json) do
      {:ok, msg} ->
        state = handle_op(msg, state)
        # Forward raw JSON to the Discord plugin for application-level handling
        send(state.handler_pid, {:discord_event, json})
        state

      {:error, reason} ->
        Logger.error("[Discord.Gateway] JSON decode error: #{inspect(reason)}")
        state
    end
  end

  # ── Private: Discord opcode handling ─────────────────────────────────────

  defp handle_op(%{"op" => @op_hello, "d" => %{"heartbeat_interval" => interval}}, state) do
    Logger.info("[Discord.Gateway] HELLO — interval: #{interval}ms, sending IDENTIFY")

    state = cancel_heartbeat(state)

    # Send IDENTIFY
    identify = build_identify(state.token)

    state =
      case send_ws_frame(state, {:text, Jason.encode!(identify)}) do
        {:ok, state} -> state
        {:error, reason, state} ->
          Logger.error("[Discord.Gateway] IDENTIFY failed: #{inspect(reason)}")
          state
      end

    # Schedule first heartbeat
    ref = Process.send_after(self(), :heartbeat, interval)
    %{state | heartbeat_interval: interval, heartbeat_ref: ref}
  end

  defp handle_op(%{"op" => @op_heartbeat_ack}, state) do
    Logger.debug("[Discord.Gateway] heartbeat ACK")
    state
  end

  defp handle_op(%{"op" => 0, "t" => "READY", "d" => data, "s" => seq}, state) do
    session_id = data["session_id"]
    Logger.info("[Discord.Gateway] READY — bot online, session: #{session_id}")
    %{state | session_id: session_id, sequence: seq}
  end

  defp handle_op(%{"op" => 0, "s" => seq}, state) when not is_nil(seq) do
    %{state | sequence: seq}
  end

  defp handle_op(_msg, state), do: state

  # ── Private: Send WebSocket frame ─────────────────────────────────────────

  defp send_ws_frame(%{conn: nil} = state, _frame), do: {:error, :not_connected, state}

  defp send_ws_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | websocket: websocket, conn: conn}}

          {:error, conn, reason} ->
            {:error, reason, %{state | websocket: websocket, conn: conn}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  # ── Private: Zlib ─────────────────────────────────────────────────────────

  defp inflate_frame(nil, _data), do: {:error, :no_context}

  defp inflate_frame(z, data) do
    # Discord zlib-stream: each complete message ends with 0x00 0x00 0xFF 0xFF
    complete? = byte_size(data) >= 4 and
      binary_part(data, byte_size(data) - 4, 4) == @zlib_suffix

    if complete? do
      try do
        inflated = :zlib.inflate(z, data)
        {:ok, IO.iodata_to_binary(inflated)}
      catch
        kind, reason ->
          Logger.error("[Discord.Gateway] inflate error: #{kind} #{inspect(reason)}")
          {:error, {kind, reason}}
      end
    else
      # Partial frame — inflate anyway to keep zlib context state consistent
      try do
        :zlib.inflate(z, data)
        {:error, :partial}
      catch
        _, _ -> {:error, :partial}
      end
    end
  end

  # ── Private: Reconnect ────────────────────────────────────────────────────

  defp schedule_reconnect(state) do
    Logger.warning("[Discord.Gateway] scheduling reconnect in #{state.backoff}ms")

    state = cancel_heartbeat(state)
    state = cleanup_zlib(state)

    if state.conn do
      try do
        Mint.HTTP.close(state.conn)
      rescue
        _ -> :ok
      end
    end

    Process.send_after(self(), :connect, state.backoff)

    %{state |
      conn: nil,
      websocket: nil,
      ref: nil,
      status: :disconnected,
      buffered_data: [],
      backoff: min(state.backoff * 2, @backoff_max)
    }
  end

  defp cancel_heartbeat(%{heartbeat_ref: nil} = state), do: state
  defp cancel_heartbeat(%{heartbeat_ref: ref} = state) do
    Process.cancel_timer(ref)
    %{state | heartbeat_ref: nil}
  end

  defp cleanup_zlib(%{zlib_context: nil} = state), do: state
  defp cleanup_zlib(%{zlib_context: z} = state) do
    try do
      :zlib.inflateEnd(z)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    try do
      :zlib.close(z)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end

    %{state | zlib_context: nil}
  end

  # ── Private: IDENTIFY payload ─────────────────────────────────────────────

  defp build_identify(token) do
    %{
      "op" => @op_identify,
      "d" => %{
        "token" => token,
        "intents" => @gateway_intents,
        "properties" => %{
          "os" => "beam",
          "browser" => "kyber",
          "device" => "kyber"
        }
      }
    }
  end
end
