defmodule Kyber.Plugin.Discord.Gateway do
  @moduledoc """
  Discord Gateway WebSocket client using Mint.WebSocket.

  Handles the full lifecycle of a Discord Gateway connection:
  - Fetches gateway URL via REST
  - Connects via Mint.HTTP + upgrades to WebSocket
  - Receives HELLO → starts heartbeat, sends IDENTIFY
  - Receives READY → stores session_id
  - Receives MESSAGE_CREATE and other DISPATCHes → forwards to handler_pid
  - Heartbeat timer → sends heartbeat, resets timer
  - On disconnect → reconnects with exponential backoff (1s, 2s, 4s, max 30s)

  The handler_pid receives `{:discord_event, raw_json_binary}` messages.
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
  @op_hello 10
  @op_heartbeat_ack 11

  @gateway_intents 34307

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

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    token = Keyword.fetch!(opts, :token)
    handler_pid = Keyword.fetch!(opts, :handler_pid)

    state = %{
      token: token,
      handler_pid: handler_pid,
      conn: nil,
      websocket: nil,
      ref: nil,
      sequence: nil,
      session_id: nil,
      heartbeat_ref: nil,
      heartbeat_interval: nil,
      zlib_context: nil,
      backoff: @backoff_initial,
      status: :disconnected
    }

    send(self(), :connect)
    {:ok, state}
  end

  @impl true
  def handle_info(:connect, state) do
    Logger.info("[Discord.Gateway] connecting to #{@gateway_host}...")

    # Clean up any existing zlib context
    state = cleanup_zlib(state)

    case do_connect(state.token) do
      {:ok, conn, websocket, ref} ->
        # Initialize a new zlib inflate context for this connection
        z = :zlib.open()
        :zlib.inflateInit(z)

        new_state = %{state |
          conn: conn,
          websocket: websocket,
          ref: ref,
          zlib_context: z,
          status: :connected,
          backoff: @backoff_initial
        }

        {:noreply, new_state}

      {:error, reason} ->
        Logger.error("[Discord.Gateway] connection failed: #{inspect(reason)}, retrying in #{state.backoff}ms")
        Process.send_after(self(), :connect, state.backoff)
        new_backoff = min(state.backoff * 2, @backoff_max)
        {:noreply, %{state | status: :disconnected, backoff: new_backoff}}
    end
  end

  def handle_info(:heartbeat, state) do
    case send_frame(state, {:text, Jason.encode!(%{"op" => @op_heartbeat, "d" => state.sequence})}) do
      {:ok, new_state} ->
        ref = Process.send_after(self(), :heartbeat, new_state.heartbeat_interval)
        {:noreply, %{new_state | heartbeat_ref: ref}}

      {:error, reason, new_state} ->
        Logger.error("[Discord.Gateway] heartbeat send failed: #{inspect(reason)}")
        {:noreply, schedule_reconnect(new_state)}
    end
  end

  # Handle Mint TCP/SSL messages
  def handle_info(message, %{conn: conn} = state) when not is_nil(conn) do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = Enum.reduce(responses, state, &handle_response/2)
        {:noreply, state}

      {:error, conn, %Mint.WebSocketError{} = error, _responses} ->
        Logger.error("[Discord.Gateway] WebSocket error: #{inspect(error)}")
        {:noreply, schedule_reconnect(%{state | conn: conn})}

      {:error, conn, error, _responses} ->
        Logger.error("[Discord.Gateway] stream error: #{inspect(error)}")
        {:noreply, schedule_reconnect(%{state | conn: conn})}

      :unknown ->
        Logger.debug("[Discord.Gateway] unhandled message: #{inspect(message)}")
        {:noreply, state}
    end
  end

  def handle_info(message, state) do
    Logger.debug("[Discord.Gateway] unhandled message (no conn): #{inspect(message)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, state) do
    cleanup_zlib(state)

    if state.conn do
      Mint.HTTP.close(state.conn)
    end

    :ok
  end

  # ── Private: Connection ───────────────────────────────────────────────────

  defp do_connect(token) do
    with {:ok, _url} <- fetch_gateway_url(token),
         {:ok, conn} <- Mint.HTTP.connect(:https, @gateway_host, @gateway_port),
         {:ok, conn, ref} <- upgrade_to_websocket(conn) do
      # Wait for the HTTP upgrade response
      receive_upgrade_response(conn, ref)
    else
      {:error, _conn, error} -> {:error, error}
      {:error, reason} -> {:error, reason}
    end
  end

  defp upgrade_to_websocket(conn) do
    case Mint.WebSocket.upgrade(:wss, conn, @gateway_path, []) do
      {:ok, conn, ref} -> {:ok, conn, ref}
      {:error, conn, error} -> {:error, conn, error}
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

      {:ok, %{status: status, body: body}} ->
        Logger.error("[Discord.Gateway] /gateway/bot returned #{status}: #{inspect(body)}")
        # Fall back to default gateway — Discord allows this
        {:ok, "wss://#{@gateway_host}"}

      {:error, reason} ->
        Logger.warning("[Discord.Gateway] /gateway/bot failed: #{inspect(reason)}, using default")
        {:ok, "wss://#{@gateway_host}"}
    end
  end

  defp receive_upgrade_response(conn, ref) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = Enum.find_value(responses, fn
              {:status, ^ref, s} -> s
              _ -> nil
            end)

            headers = Enum.find_value(responses, fn
              {:headers, ^ref, h} -> h
              _ -> nil
            end)

            done? = Enum.any?(responses, fn
              {:done, ^ref} -> true
              _ -> false
            end)

            if done? && status && headers do
              case Mint.WebSocket.new(conn, ref, status, headers) do
                {:ok, conn, websocket} ->
                  Logger.info("[Discord.Gateway] WebSocket upgrade successful")
                  {:ok, conn, websocket, ref}

                {:error, _conn, reason} ->
                  Logger.error("[Discord.Gateway] WebSocket upgrade failed: #{inspect(reason)}")
                  {:error, reason}
              end
            else
              # Keep accumulating until we get :done
              receive_upgrade_response_continue(conn, ref, status, headers)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            receive_upgrade_response(conn, ref)
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  defp receive_upgrade_response_continue(conn, ref, acc_status, acc_headers) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, responses} ->
            status = acc_status || Enum.find_value(responses, fn
              {:status, ^ref, s} -> s
              _ -> nil
            end)

            headers = acc_headers || Enum.find_value(responses, fn
              {:headers, ^ref, h} -> h
              _ -> nil
            end)

            done? = Enum.any?(responses, fn
              {:done, ^ref} -> true
              _ -> false
            end)

            if done? && status && headers do
              case Mint.WebSocket.new(conn, ref, status, headers) do
                {:ok, conn, websocket} ->
                  Logger.info("[Discord.Gateway] WebSocket upgrade successful")
                  {:ok, conn, websocket, ref}

                {:error, _conn, reason} ->
                  {:error, reason}
              end
            else
              receive_upgrade_response_continue(conn, ref, status, headers)
            end

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            receive_upgrade_response_continue(conn, ref, acc_status, acc_headers)
        end
    after
      10_000 -> {:error, :upgrade_timeout}
    end
  end

  # ── Private: Frame handling ───────────────────────────────────────────────

  defp handle_response({:data, _ref, data}, state) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &handle_frame/2)

      {:error, websocket, reason} ->
        Logger.error("[Discord.Gateway] decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp handle_response({:error, _ref, reason}, state) do
    Logger.error("[Discord.Gateway] response error: #{inspect(reason)}")
    schedule_reconnect(state)
  end

  defp handle_response(_other, state), do: state

  # Binary frame (possibly zlib-compressed)
  defp handle_frame({:binary, data}, state) do
    case inflate_zlib(state.zlib_context, data) do
      {:ok, json} ->
        dispatch_event(json, state)

      {:error, reason} ->
        Logger.error("[Discord.Gateway] zlib inflate failed: #{inspect(reason)}")
        state
    end
  end

  # Text frame (uncompressed JSON)
  defp handle_frame({:text, json}, state) do
    dispatch_event(json, state)
  end

  # Ping frame — respond with pong
  defp handle_frame({:ping, data}, state) do
    case send_frame(state, {:pong, data}) do
      {:ok, new_state} -> new_state
      {:error, _, new_state} -> new_state
    end
  end

  # Close frame
  defp handle_frame({:close, code, reason}, state) do
    Logger.warning("[Discord.Gateway] server closed connection: #{code} #{reason}")
    schedule_reconnect(state)
  end

  defp handle_frame(_frame, state), do: state

  defp dispatch_event(json, state) do
    case Jason.decode(json) do
      {:ok, msg} ->
        state = handle_gateway_op(msg, state)
        # Forward raw JSON to handler for any processing it needs
        send(state.handler_pid, {:discord_event, json})
        state

      {:error, reason} ->
        Logger.error("[Discord.Gateway] JSON decode error: #{inspect(reason)}")
        state
    end
  end

  # ── Private: Gateway opcode handling ─────────────────────────────────────

  defp handle_gateway_op(%{"op" => @op_hello, "d" => %{"heartbeat_interval" => interval}}, state) do
    Logger.info("[Discord.Gateway] HELLO received, heartbeat_interval: #{interval}ms")

    # Cancel old heartbeat if any
    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    # Send IDENTIFY immediately
    identify_payload = build_identify(state.token)

    case send_frame(state, {:text, Jason.encode!(identify_payload)}) do
      {:ok, new_state} ->
        ref = Process.send_after(self(), :heartbeat, interval)
        %{new_state | heartbeat_interval: interval, heartbeat_ref: ref}

      {:error, reason, new_state} ->
        Logger.error("[Discord.Gateway] failed to send IDENTIFY: #{inspect(reason)}")
        new_state
    end
  end

  defp handle_gateway_op(%{"op" => @op_heartbeat_ack}, state) do
    Logger.debug("[Discord.Gateway] heartbeat ACK")
    state
  end

  defp handle_gateway_op(%{"op" => 0, "t" => "READY", "d" => data, "s" => seq}, state) do
    session_id = data["session_id"]
    Logger.info("[Discord.Gateway] READY — session_id: #{session_id}")
    %{state | session_id: session_id, sequence: seq}
  end

  defp handle_gateway_op(%{"op" => 0, "s" => seq}, state) when not is_nil(seq) do
    %{state | sequence: seq}
  end

  defp handle_gateway_op(_msg, state), do: state

  # ── Private: Sending frames ───────────────────────────────────────────────

  defp send_frame(%{conn: nil} = state, _frame), do: {:error, :not_connected, state}

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(conn_from_state(state), state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | websocket: websocket, conn: conn}}

          {:error, conn, reason} ->
            {:error, reason, %{state | websocket: websocket, conn: conn}}
        end

      {:error, websocket, reason} ->
        {:error, reason, %{state | websocket: websocket}}
    end
  end

  defp conn_from_state(%{conn: conn}), do: conn

  # ── Private: Zlib ─────────────────────────────────────────────────────────

  defp inflate_zlib(nil, _data), do: {:error, :no_zlib_context}

  defp inflate_zlib(z, data) do
    # Discord uses zlib-stream compression: each message ends with 0x00 0x00 0xFF 0xFF
    # We need to check if this is a complete message boundary
    if :binary.longest_common_suffix([data, @zlib_suffix]) == byte_size(@zlib_suffix) do
      try do
        inflated = :zlib.inflate(z, data)
        {:ok, IO.iodata_to_binary(inflated)}
      catch
        kind, reason ->
          Logger.error("[Discord.Gateway] zlib inflate error: #{kind} #{inspect(reason)}")
          {:error, {kind, reason}}
      end
    else
      # Partial message — accumulate (Discord shouldn't send partial WS frames but just in case)
      try do
        _inflated = :zlib.inflate(z, data)
        {:error, :partial_message}
      catch
        kind, reason ->
          {:error, {kind, reason}}
      end
    end
  end

  # ── Private: Reconnect ────────────────────────────────────────────────────

  defp schedule_reconnect(state) do
    Logger.warning("[Discord.Gateway] scheduling reconnect in #{state.backoff}ms")

    if state.heartbeat_ref, do: Process.cancel_timer(state.heartbeat_ref)

    if state.conn do
      try do
        Mint.HTTP.close(state.conn)
      rescue
        _ -> :ok
      end
    end

    state = cleanup_zlib(state)
    Process.send_after(self(), :connect, state.backoff)
    new_backoff = min(state.backoff * 2, @backoff_max)

    %{state |
      conn: nil,
      websocket: nil,
      ref: nil,
      heartbeat_ref: nil,
      backoff: new_backoff,
      status: :disconnected
    }
  end

  defp cleanup_zlib(%{zlib_context: nil} = state), do: state
  defp cleanup_zlib(%{zlib_context: z} = state) do
    try do
      :zlib.inflateEnd(z)
      :zlib.close(z)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
    %{state | zlib_context: nil}
  end

  # ── Private: Protocol ─────────────────────────────────────────────────────

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
