defmodule Kyber.Plugin.LLM do
  @moduledoc """
  Anthropic API integration — GenServer lifecycle and effect handler registration.

  Delegates actual work to focused modules:
  - `ApiClient` — HTTP calls, auth, retry/backoff
  - `PromptBuilder` — System prompt, messages, memory
  - `ToolLoop` — Multi-turn tool execution
  - `Streamer` — SSE streaming
  """

  @behaviour Kyber.Plugin.Behaviour

  use GenServer
  require Logger

  alias Kyber.Plugin.LLM.{ApiClient, PromptBuilder, ToolLoop}

  @auth_profiles_path "~/.openclaw/agents/main/agent/auth-profiles.json"

  # ── Plugin behaviour ──────────────────────────────────────────────────────

  @impl Kyber.Plugin.Behaviour
  def name, do: "llm"

  # ── Public API (delegates) ────────────────────────────────────────────────

  defdelegate detect_auth_type(token), to: ApiClient
  defdelegate build_headers(auth_config), to: ApiClient
  defdelegate build_messages(payload), to: PromptBuilder
  defdelegate call_api(auth_config, params), to: ApiClient
  defdelegate format_with_reasoning(text, thinking), to: ApiClient

  @doc "Start the LLM plugin."
  @impl Kyber.Plugin.Behaviour
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {name, opts} = Keyword.pop(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Load auth configuration from auth-profiles.json (default path)."
  @spec load_auth_config() :: {:ok, map()} | {:error, term()}
  def load_auth_config, do: ApiClient.load_auth_config(@auth_profiles_path)

  @doc "Load auth configuration from a specific path."
  @spec load_auth_config(String.t()) :: {:ok, map()} | {:error, term()}
  def load_auth_config(path), do: ApiClient.load_auth_config(path)

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    core = Keyword.get(opts, :core, Kyber.Core)
    session = Keyword.get(opts, :session, Kyber.Session)
    auth_path = Keyword.get(opts, :auth_path, @auth_profiles_path)

    state = %{
      core: core,
      session: session,
      auth_config: nil,
      auth_path: auth_path,
      executor_monitor: nil,
      api_calls: []
    }

    case ApiClient.load_auth_config(auth_path) do
      {:ok, auth_config} ->
        Logger.info("[Kyber.Plugin.LLM] auth loaded (type: #{auth_config.type})")
        state = %{state | auth_config: auth_config}
        send(self(), :register_handlers)
        {:ok, state}

      {:error, reason} ->
        Logger.warning(
          "[Kyber.Plugin.LLM] auth load failed: #{inspect(reason)} — plugin will run without auth"
        )

        send(self(), :register_handlers)
        {:ok, state}
    end
  end

  @impl true
  def handle_info(:register_handlers, state) do
    state = register_effect_handler(state)
    Logger.info("[Kyber.Plugin.LLM] effect handler registered")
    {:noreply, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{executor_monitor: ref} = state) do
    Logger.warning(
      "[Kyber.Plugin.LLM] Effect.Executor went down (#{inspect(reason)}) — " <>
        "attempting immediate re-registration"
    )

    state = %{state | executor_monitor: nil}
    executor = find_executor(state.core)

    if executor && Process.alive?(executor) do
      state = register_effect_handler(state)
      Logger.info("[Kyber.Plugin.LLM] effect handler re-registered immediately after :DOWN")
      {:noreply, state}
    else
      Process.send_after(self(), :reregister_after_core_restart, 500)
      {:noreply, state}
    end
  end

  def handle_info(:reregister_after_core_restart, state) do
    executor = find_executor(state.core)

    if executor && Process.alive?(executor) do
      state = register_effect_handler(state)
      Logger.info("[Kyber.Plugin.LLM] effect handler re-registered after Core restart")
      {:noreply, state}
    else
      Process.send_after(self(), :reregister_after_core_restart, 500)
      {:noreply, state}
    end
  end

  def handle_info({:update_auth, auth_config}, state) do
    {:noreply, %{state | auth_config: auth_config}}
  end

  def handle_info(msg, state) do
    Logger.debug("[Kyber.Plugin.LLM] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_auth_config, _from, state) do
    {:reply, state.auth_config, state}
  end

  def handle_call(:check_rate_limit, _from, state) do
    case check_rate_limit(state) do
      {:ok, new_state} -> {:reply, :ok, new_state}
      {:error, :rate_limited} = err -> {:reply, err, state}
    end
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("[Kyber.Plugin.LLM] terminating: #{inspect(reason)}")
    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp find_executor(core) do
    executor_name = :"#{core}.Executor"

    case Process.whereis(executor_name) do
      nil ->
        try do
          Supervisor.which_children(core)
          |> Enum.find_value(fn
            {Kyber.Effect.Executor, pid, _, _} when is_pid(pid) -> pid
            _ -> nil
          end)
        catch
          _, _ -> nil
        end

      pid ->
        pid
    end
  end

  defp register_effect_handler(%{core: core, session: session} = state) do
    plugin_pid = self()

    handler = fn effect ->
      case GenServer.call(plugin_pid, :check_rate_limit) do
        :ok ->
          auth_config = GenServer.call(plugin_pid, :get_auth_config)
          ToolLoop.handle_llm_call(effect, core, session, auth_config)

        {:error, :rate_limited} ->
          origin = Map.get(effect, :origin)
          parent_id = Map.get(effect, :delta_id)

          delta =
            Kyber.Delta.new(
              "llm.error",
              %{"error" => "rate limited: too many LLM calls, please wait", "status" => 429},
              origin || {:system, "llm"},
              parent_id
            )

          try do
            Kyber.Core.emit(core, delta)
          rescue
            e -> Logger.error("[Kyber.Plugin.LLM] failed to emit rate limit error: #{inspect(e)}")
          end
      end
    end

    try do
      Kyber.Core.register_effect_handler(core, :llm_call, handler)

      if old_ref = state[:executor_monitor], do: Process.demonitor(old_ref, [:flush])

      executor_monitor =
        case find_executor(core) do
          nil -> nil
          pid -> Process.monitor(pid)
        end

      %{state | executor_monitor: executor_monitor}
    catch
      :exit, reason ->
        Logger.warning(
          "[Kyber.Plugin.LLM] could not register handler (core not ready): #{inspect(reason)}"
        )

        state

      kind, reason ->
        Logger.error(
          "[Kyber.Plugin.LLM] failed to register handler: #{kind} #{inspect(reason)}"
        )

        state
    end
  end

  defp check_rate_limit(state) do
    window = 60_000
    max_calls = Kyber.Config.get(:max_llm_calls_per_minute, 30)
    now = System.monotonic_time(:millisecond)
    recent = Enum.filter(state.api_calls, &(&1 > now - window))

    if length(recent) >= max_calls do
      Logger.warning(
        "[Kyber.Plugin.LLM] rate limit reached (#{length(recent)}/#{max_calls} calls in last 60s)"
      )

      {:error, :rate_limited}
    else
      {:ok, %{state | api_calls: [now | recent]}}
    end
  end
end
