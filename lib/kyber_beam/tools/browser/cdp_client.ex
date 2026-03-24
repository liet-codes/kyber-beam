defmodule Kyber.Tools.Browser.CdpClient do
  @moduledoc """
  CDP (Chrome DevTools Protocol) WebSocket client using Mint + MintWebSocket.

  Connects to a Chrome page target's WebSocket debug URL and provides
  synchronous command execution with request ID tracking.

  ## Usage

      {:ok, pid} = CdpClient.start_link(ws_url: "ws://localhost:9222/devtools/page/ABC123")
      {:ok, result} = CdpClient.send_command(pid, "Page.navigate", %{url: "https://example.com"})
  """

  use GenServer
  require Logger

  @connect_timeout 5_000
  @command_timeout 10_000

  defstruct [
    :ws_url,
    :conn,
    :websocket,
    :ref,
    :request_id,
    :pending,
    :buffer
  ]

  # ── Public API ──────────────────────────────────────────────────────────

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Send a CDP command and wait for the response.
  Returns `{:ok, result_map}` or `{:error, reason}`.
  """
  def send_command(pid, method, params \\ %{}, timeout \\ @command_timeout) do
    GenServer.call(pid, {:send_command, method, params}, timeout + 1_000)
  end

  @doc "Disconnect and stop the client."
  def disconnect(pid) do
    GenServer.stop(pid, :normal)
  end

  # ── GenServer Callbacks ────────────────────────────────────────────────

  @impl true
  def init(opts) do
    ws_url = Keyword.fetch!(opts, :ws_url)

    state = %__MODULE__{
      ws_url: ws_url,
      request_id: 0,
      pending: %{},
      buffer: []
    }

    case do_connect(state) do
      {:ok, state} ->
        {:ok, state}

      {:error, reason} ->
        {:stop, {:connect_failed, reason}}
    end
  end

  @impl true
  def handle_call({:send_command, method, params}, from, state) do
    id = state.request_id + 1

    message =
      Jason.encode!(%{
        "id" => id,
        "method" => method,
        "params" => params
      })

    case send_frame(state, {:text, message}) do
      {:ok, state} ->
        # Set up a timer for timeout
        timer_ref = Process.send_after(self(), {:command_timeout, id}, @command_timeout)

        pending = Map.put(state.pending, id, %{from: from, timer: timer_ref})
        {:noreply, %{state | request_id: id, pending: pending}}

      {:error, reason} ->
        {:reply, {:error, {:send_failed, reason}}, state}
    end
  end

  @impl true
  def handle_info({:command_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {nil, _pending} ->
        {:noreply, state}

      {%{from: from}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}
    end
  end

  def handle_info(message, state) do
    case Mint.WebSocket.stream(state.conn, message) do
      {:ok, conn, responses} ->
        state = %{state | conn: conn}
        state = process_responses(state, responses)
        {:noreply, state}

      {:error, conn, reason, _responses} ->
        Logger.error("[CdpClient] WebSocket stream error: #{inspect(reason)}")
        {:noreply, %{state | conn: conn}}

      :unknown ->
        {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    if state.conn && state.websocket do
      try do
        {:ok, conn, data} = Mint.WebSocket.encode(state.websocket, :close)
        Mint.HTTP.stream_request_body(conn, state.ref, data)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    :ok
  end

  # ── Connection ─────────────────────────────────────────────────────────

  defp do_connect(state) do
    uri = URI.parse(state.ws_url)
    scheme = if uri.scheme in ["wss", "https"], do: :https, else: :http
    port = uri.port || if(scheme == :https, do: 443, else: 80)
    path = uri.path || "/"

    with {:ok, conn} <- Mint.HTTP.connect(scheme, uri.host, port, protocols: [:http1], transport_opts: [timeout: @connect_timeout]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(scheme, conn, path, []) do
      # Wait for the upgrade response
      receive_upgrade_response(conn, ref, state)
    else
      {:error, reason} ->
        {:error, reason}

      {:error, _conn, reason} ->
        {:error, reason}
    end
  end

  defp receive_upgrade_response(conn, ref, state) do
    receive do
      message ->
        case Mint.WebSocket.stream(conn, message) do
          {:ok, conn, [{:status, ^ref, 101}, {:headers, ^ref, headers}, {:done, ^ref}]} ->
            case Mint.WebSocket.new(conn, ref, 101, headers) do
              {:ok, conn, websocket} ->
                {:ok, %{state | conn: conn, websocket: websocket, ref: ref}}

              {:error, _conn, reason} ->
                {:error, reason}
            end

          {:ok, conn, responses} ->
            # May get partial responses, accumulate them
            handle_partial_upgrade(conn, ref, state, responses)

          {:error, _conn, reason, _} ->
            {:error, reason}

          :unknown ->
            receive_upgrade_response(conn, ref, state)
        end
    after
      @connect_timeout ->
        {:error, :connect_timeout}
    end
  end

  defp handle_partial_upgrade(conn, ref, state, responses) do
    status = Enum.find_value(responses, fn {:status, ^ref, s} -> s; _ -> nil end)
    headers = Enum.find_value(responses, fn {:headers, ^ref, h} -> h; _ -> nil end)
    done = Enum.any?(responses, fn {:done, ^ref} -> true; _ -> false end)

    cond do
      status && headers && done ->
        case Mint.WebSocket.new(conn, ref, status, headers) do
          {:ok, conn, websocket} ->
            {:ok, %{state | conn: conn, websocket: websocket, ref: ref}}

          {:error, _conn, reason} ->
            {:error, reason}
        end

      true ->
        # Keep waiting for more
        receive_upgrade_response(conn, ref, state)
    end
  end

  # ── Frame Sending ──────────────────────────────────────────────────────

  defp send_frame(state, frame) do
    case Mint.WebSocket.encode(state.websocket, frame) do
      {:ok, websocket, data} ->
        case Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
          {:ok, conn} ->
            {:ok, %{state | conn: conn, websocket: websocket}}

          {:error, _conn, reason} ->
            Logger.error("[CdpClient] send error: #{inspect(reason)}")
            {:error, reason}
        end

      {:error, _websocket, reason} ->
        {:error, reason}
    end
  end

  # ── Response Processing ────────────────────────────────────────────────

  defp process_responses(state, responses) do
    Enum.reduce(responses, state, fn response, acc ->
      process_response(acc, response)
    end)
  end

  defp process_response(state, {:data, _ref, data}) do
    case Mint.WebSocket.decode(state.websocket, data) do
      {:ok, websocket, frames} ->
        state = %{state | websocket: websocket}
        Enum.reduce(frames, state, &handle_frame/2)

      {:error, websocket, reason} ->
        Logger.error("[CdpClient] decode error: #{inspect(reason)}")
        %{state | websocket: websocket}
    end
  end

  defp process_response(state, _other), do: state

  defp handle_frame({:text, text}, state) do
    case Jason.decode(text) do
      {:ok, %{"id" => id} = msg} ->
        case Map.pop(state.pending, id) do
          {nil, _pending} ->
            state

          {%{from: from, timer: timer}, pending} ->
            Process.cancel_timer(timer)

            reply =
              if Map.has_key?(msg, "error") do
                {:error, msg["error"]}
              else
                {:ok, Map.get(msg, "result", %{})}
              end

            GenServer.reply(from, reply)
            %{state | pending: pending}
        end

      {:ok, %{"method" => _method} = _event} ->
        # CDP events (Page.loadEventFired, etc.) — ignore for now
        state

      {:error, _} ->
        Logger.warning("[CdpClient] failed to decode CDP message")
        state
    end
  end

  defp handle_frame({:close, _code, _reason}, state) do
    Logger.warning("[CdpClient] WebSocket closed by server")
    state
  end

  defp handle_frame(_frame, state), do: state
end
