defmodule Kyber.Plugin.LLM.AgentSdk do
  @moduledoc """
  Bridge to the Claude Agent SDK via a Node.js child process (Erlang Port).

  Communicates over stdin/stdout JSON lines with priv/agent-sdk/bridge.js.
  Falls back to the direct API client (ApiClient) if the bridge is unavailable.

  ## Configuration

      config :kyber_beam, :llm_backend, :agent_sdk   # or :api (default)

  ## Protocol

  Outgoing (Elixir → Node):
    - `{"id":"...","type":"prompt","prompt":"...","system":"...","tools":[...]}`
    - `{"id":"...","type":"tool_result","tool_use_id":"...","content":"..."}`
    - `{"id":"...","type":"ping"}`

  Incoming (Node → Elixir):
    - `{"id":"...","type":"response","content":"...","tool_calls":[...],...}`
    - `{"id":"...","type":"error","error":"..."}`
    - `{"type":"ready","agent_sdk_available":true}`
    - `{"id":"...","type":"pong","agent_sdk_available":true}`
  """

  use GenServer
  require Logger

  @bridge_script "priv/agent-sdk/bridge.js"
  @startup_timeout 10_000
  @call_timeout 120_000

  # ── Public API ─────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Check if the Agent SDK bridge is running and available.
  """
  @spec available?() :: boolean()
  def available? do
    available?(__MODULE__)
  end

  @spec available?(GenServer.server()) :: boolean()
  def available?(server) do
    try do
      GenServer.call(server, :available?, 5_000)
    catch
      :exit, _ -> false
    end
  end

  @doc """
  Send a prompt to the Agent SDK and get a response.

  Returns `{:ok, response_map}` or `{:error, reason}`.
  The response_map is shaped like an Anthropic Messages API response for
  compatibility with the existing ToolLoop.
  """
  @spec call_prompt(map()) :: {:ok, map()} | {:error, term()}
  def call_prompt(params) do
    call_prompt(__MODULE__, params)
  end

  @spec call_prompt(GenServer.server(), map()) :: {:ok, map()} | {:error, term()}
  def call_prompt(server, params) do
    try do
      GenServer.call(server, {:prompt, params}, @call_timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, {:bridge_exit, reason}}
    end
  end

  @doc """
  Send a tool result back to the Agent SDK for an ongoing conversation.
  """
  @spec send_tool_result(String.t(), String.t(), term()) :: {:ok, map()} | {:error, term()}
  def send_tool_result(request_id, tool_use_id, content) do
    send_tool_result(__MODULE__, request_id, tool_use_id, content)
  end

  @spec send_tool_result(GenServer.server(), String.t(), String.t(), term()) ::
          {:ok, map()} | {:error, term()}
  def send_tool_result(server, request_id, tool_use_id, content) do
    try do
      GenServer.call(server, {:tool_result, request_id, tool_use_id, content}, @call_timeout)
    catch
      :exit, {:timeout, _} -> {:error, :timeout}
      :exit, reason -> {:error, {:bridge_exit, reason}}
    end
  end

  # ── GenServer callbacks ────────────────────────────────────────────────

  @impl true
  def init(_opts) do
    state = %{
      port: nil,
      sdk_available: false,
      pending: %{},
      buffer: ""
    }

    case start_bridge() do
      {:ok, port} ->
        Logger.info("[AgentSdk] bridge process started")
        {:ok, %{state | port: port}, @startup_timeout}

      {:error, reason} ->
        Logger.warning("[AgentSdk] bridge failed to start: #{inspect(reason)} — running without Agent SDK")
        {:ok, state}
    end
  end

  @impl true
  def handle_call(:available?, _from, state) do
    {:reply, state.port != nil && state.sdk_available, state}
  end

  def handle_call({:prompt, params}, from, %{port: port} = state) when port != nil do
    id = generate_id()

    msg = %{
      id: id,
      type: "prompt",
      prompt: params["prompt"] || params[:prompt],
      system: params["system"] || params[:system],
      tools: params["tools"] || params[:tools] || [],
      model: params["model"] || params[:model],
      messages: params["messages"] || params[:messages]
    }

    send_to_bridge(port, msg)
    pending = Map.put(state.pending, id, from)
    {:noreply, %{state | pending: pending}}
  end

  def handle_call({:prompt, _params}, _from, state) do
    {:reply, {:error, :bridge_not_running}, state}
  end

  def handle_call({:tool_result, request_id, tool_use_id, content}, from, %{port: port} = state)
      when port != nil do
    msg = %{
      id: request_id,
      type: "tool_result",
      tool_use_id: tool_use_id,
      content: content
    }

    send_to_bridge(port, msg)
    pending = Map.put(state.pending, request_id, from)
    {:noreply, %{state | pending: pending}}
  end

  def handle_call({:tool_result, _id, _tuid, _content}, _from, state) do
    {:reply, {:error, :bridge_not_running}, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    state = process_data(state, IO.iodata_to_binary(data))
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("[AgentSdk] bridge exited with code #{code}")

    # Fail all pending requests
    for {_id, from} <- state.pending do
      GenServer.reply(from, {:error, :bridge_exited})
    end

    {:noreply, %{state | port: nil, sdk_available: false, pending: %{}, buffer: ""}}
  end

  # Startup timeout — if we haven't received a ready message, mark as unavailable
  def handle_info(:timeout, state) do
    if !state.sdk_available do
      Logger.warning("[AgentSdk] bridge startup timed out — SDK may not be available")
    end

    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("[AgentSdk] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{port: port}) when port != nil do
    Port.close(port)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  # ── Private ────────────────────────────────────────────────────────────

  defp start_bridge do
    bridge_path = Path.join(Application.app_dir(:kyber_beam), @bridge_script)

    # Fall back to repo-relative path if running in dev
    bridge_path =
      if File.exists?(bridge_path) do
        bridge_path
      else
        Path.join(File.cwd!(), @bridge_script)
      end

    node_modules = Path.join(Path.dirname(bridge_path), "node_modules")

    unless File.exists?(bridge_path) do
      {:error, :bridge_script_not_found}
    else
      unless File.dir?(node_modules) do
        Logger.warning("[AgentSdk] node_modules not found — run: cd priv/agent-sdk && npm install")
      end

      node = System.find_executable("node")

      unless node do
        {:error, :node_not_found}
      else
        port =
          Port.open({:spawn_executable, node}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stderr_to_stderr,
            args: [bridge_path],
            cd: Path.dirname(bridge_path)
          ])

        {:ok, port}
      end
    end
  end

  defp send_to_bridge(port, msg) do
    json = Jason.encode!(msg) <> "\n"
    Port.command(port, json)
  end

  defp process_data(state, new_data) do
    buffer = state.buffer <> new_data
    {lines, rest} = split_lines(buffer)

    state = %{state | buffer: rest}

    Enum.reduce(lines, state, fn line, acc ->
      case Jason.decode(line) do
        {:ok, msg} -> handle_bridge_message(acc, msg)
        {:error, _} ->
          Logger.debug("[AgentSdk] ignoring non-JSON line: #{String.slice(line, 0, 100)}")
          acc
      end
    end)
  end

  defp split_lines(buffer) do
    case String.split(buffer, "\n", parts: :infinity) do
      [] -> {[], ""}
      parts ->
        {complete, [rest]} = Enum.split(parts, -1)
        {Enum.reject(complete, &(&1 == "")), rest}
    end
  end

  defp handle_bridge_message(state, %{"type" => "ready"} = msg) do
    sdk = Map.get(msg, "agent_sdk_available", false)
    Logger.info("[AgentSdk] bridge ready (agent_sdk_available: #{sdk})")
    %{state | sdk_available: sdk}
  end

  defp handle_bridge_message(state, %{"type" => "pong"} = msg) do
    id = msg["id"]

    case Map.pop(state.pending, id) do
      {nil, _} -> state
      {from, pending} ->
        GenServer.reply(from, {:ok, msg})
        %{state | pending: pending}
    end
  end

  defp handle_bridge_message(state, %{"type" => "response", "id" => id} = msg) do
    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.warning("[AgentSdk] response for unknown request: #{id}")
        state

      {from, pending} ->
        # Reshape into Anthropic Messages API format for ToolLoop compatibility
        response = normalize_response(msg)
        GenServer.reply(from, {:ok, response})
        %{state | pending: pending}
    end
  end

  defp handle_bridge_message(state, %{"type" => "error", "id" => id} = msg) do
    error = Map.get(msg, "error", "unknown error")

    case Map.pop(state.pending, id) do
      {nil, _} ->
        Logger.warning("[AgentSdk] error for unknown request #{id}: #{error}")
        state

      {from, pending} ->
        GenServer.reply(from, {:error, error})
        %{state | pending: pending}
    end
  end

  defp handle_bridge_message(state, msg) do
    Logger.debug("[AgentSdk] unhandled bridge message: #{inspect(msg)}")
    state
  end

  # Normalize Agent SDK response into Anthropic Messages API shape
  # so ToolLoop can process it without changes.
  defp normalize_response(msg) do
    content_blocks = msg["content_blocks"] || [%{"type" => "text", "text" => msg["content"] || ""}]

    tool_calls = msg["tool_calls"] || []

    # If there are tool calls, ensure they appear as content blocks
    content_blocks =
      if tool_calls != [] do
        tc_blocks =
          Enum.map(tool_calls, fn tc ->
            %{
              "type" => "tool_use",
              "id" => tc["id"],
              "name" => tc["name"],
              "input" => tc["input"] || %{}
            }
          end)

        # Keep existing non-tool_use blocks, add tool_use blocks
        existing = Enum.reject(content_blocks, &(&1["type"] == "tool_use"))
        existing ++ tc_blocks
      else
        content_blocks
      end

    stop_reason =
      cond do
        tool_calls != [] -> "tool_use"
        true -> msg["stop_reason"] || "end_turn"
      end

    %{
      "content" => content_blocks,
      "stop_reason" => stop_reason,
      "model" => msg["model"],
      "usage" => msg["usage"] || %{}
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.hex_encode32(case: :lower, padding: false)
  end
end
