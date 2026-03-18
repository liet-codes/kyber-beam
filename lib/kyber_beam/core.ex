defmodule Kyber.Core do
  @moduledoc """
  Top-level supervisor that orchestrates all Kyber components.

  ## Supervision tree

      Kyber.Core (Supervisor)
      ├── Kyber.Delta.Store        (GenServer — persists/broadcasts deltas)
      ├── Kyber.State              (Agent — holds application state)
      ├── Kyber.Effect.TaskSupervisor (Task.Supervisor — async effect tasks)
      ├── Kyber.Effect.Executor    (GenServer — dispatches effects)
      └── Kyber.Plugin.Manager     (DynamicSupervisor — plugin lifecycle)

  ## Data flow

      emit(delta)
        → Delta.Store.append        (persist + broadcast)
        → subscriber callback       (registered by Core.init)
        → Reducer.reduce            (pure: state + effects)
        → State.update              (apply state change)
        → Effect.Executor.execute   (async dispatch per effect)

  ## Usage

      {:ok, core} = Kyber.Core.start_link()
      :ok = Kyber.Core.emit(core, delta)
      :ok = Kyber.Core.register_effect_handler(core, :llm_call, &my_handler/1)
      {:ok, _pid} = Kyber.Core.register_plugin(core, MyPlugin)
  """

  use Supervisor
  require Logger

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Start the Kyber.Core supervisor and all children."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Supervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Emit a delta into the system.

  Appends to the store, which triggers the subscription pipeline:
  reduce → state update → effects executed.
  """
  @spec emit(Supervisor.supervisor(), Kyber.Delta.t()) :: :ok
  def emit(core \\ __MODULE__, %Kyber.Delta{} = delta) do
    store = store_name(core)
    Kyber.Delta.Store.append(store, delta)
  end

  @doc "Register an effect handler with the executor."
  @spec register_effect_handler(Supervisor.supervisor(), atom(), (map() -> any())) :: :ok
  def register_effect_handler(core \\ __MODULE__, effect_type, handler_fn) do
    executor = executor_name(core)
    Kyber.Effect.Executor.register(executor, effect_type, handler_fn)
  end

  @doc "Register a plugin with the plugin manager."
  @spec register_plugin(Supervisor.supervisor(), module()) :: {:ok, pid()} | {:error, any()}
  def register_plugin(core \\ __MODULE__, plugin_module) do
    mgr = plugin_manager_name(core)
    Kyber.Plugin.Manager.register(mgr, plugin_module)
  end

  @doc "Unregister a plugin by name."
  @spec unregister_plugin(Supervisor.supervisor(), String.t()) :: :ok | {:error, :not_found}
  def unregister_plugin(core \\ __MODULE__, plugin_name) do
    mgr = plugin_manager_name(core)
    Kyber.Plugin.Manager.unregister(mgr, plugin_name)
  end

  @doc "List registered plugins."
  @spec list_plugins(Supervisor.supervisor()) :: [String.t()]
  def list_plugins(core \\ __MODULE__) do
    mgr = plugin_manager_name(core)
    Kyber.Plugin.Manager.list(mgr)
  end

  @doc "Get current state."
  @spec get_state(Supervisor.supervisor()) :: Kyber.State.t()
  def get_state(core \\ __MODULE__) do
    state_name(core) |> Kyber.State.get()
  end

  @doc "Query deltas from the store."
  @spec query_deltas(Supervisor.supervisor(), keyword()) :: [Kyber.Delta.t()]
  def query_deltas(core \\ __MODULE__, filters \\ []) do
    store = store_name(core)
    Kyber.Delta.Store.query(store, filters)
  end

  # ── Supervisor callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    # Derive child names from core's own name so multiple cores can coexist
    core_name = Keyword.get(opts, :name, __MODULE__)
    store_path = Keyword.get(opts, :store_path, default_store_path())

    store = store_name(core_name)
    state = state_name(core_name)
    executor = executor_name(core_name)
    plugin_mgr = plugin_manager_name(core_name)
    task_sup = task_supervisor_name(core_name)

    children = [
      {Task.Supervisor, name: task_sup},
      {Kyber.Delta.Store, [name: store, path: store_path]},
      {Kyber.State, [name: state]},
      {Kyber.Effect.Executor, [name: executor, task_supervisor: task_sup]},
      {Kyber.Plugin.Manager, [name: plugin_mgr]}
    ]

    # Wire up the subscription pipeline after a brief delay to let
    # children register their names. We spawn a task that waits briefly
    # then subscribes to the store.
    Task.start(fn ->
      Process.sleep(50)
      subscribe_reducer(core_name, store, state, executor)
      Logger.info("[Kyber.Core] pipeline wired for #{inspect(core_name)}")
    end)

    Supervisor.init(children, strategy: :one_for_one)
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp subscribe_reducer(core_name, store, state, executor) do
    Kyber.Delta.Store.subscribe(store, fn delta ->
      # Atomically: read current state, reduce with delta, write new state.
      # Using get_and_update avoids the get/compute/update race condition
      # when multiple deltas are broadcast concurrently.
      effects =
        try do
          Kyber.State.get_and_update(state, fn current_state ->
            {new_state, effects} = Kyber.Reducer.reduce(current_state, delta)
            {effects, new_state}
          end)
        rescue
          e ->
            Logger.error("[Kyber.Core/#{inspect(core_name)}] reducer error: #{inspect(e)}\n#{Exception.format_stacktrace(__STACKTRACE__)}")
            []
        end

      Enum.each(effects, fn effect ->
        try do
          case Kyber.Effect.Executor.execute(executor, effect) do
            {:ok, _ref} -> :ok
            {:error, reason} ->
              Logger.warning("[Kyber.Core/#{inspect(core_name)}] effect dispatch failed: #{inspect(reason)}")
          end
        rescue
          e ->
            Logger.error("[Kyber.Core/#{inspect(core_name)}] effect dispatch error: #{inspect(e)}")
        end
      end)
    end)
  end

  defp default_store_path do
    data_dir = System.get_env("KYBER_DATA_DIR", "priv/data")
    File.mkdir_p!(data_dir)
    Path.join(data_dir, "deltas.jsonl")
  end

  # Name helpers — scoped to the core name to allow multiple instances.
  # When given a pid, we look up its registered name via the process registry.
  defp resolve_name(core) when is_atom(core), do: core
  defp resolve_name(core) when is_pid(core) do
    case Process.info(core, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] -> name
      _ -> core
    end
  end
  defp resolve_name(core), do: core

  defp store_name(core) do
    case resolve_name(core) do
      name when is_atom(name) -> :"#{name}.Store"
      _ -> Kyber.Delta.Store
    end
  end

  defp state_name(core) do
    case resolve_name(core) do
      name when is_atom(name) -> :"#{name}.State"
      _ -> Kyber.State
    end
  end

  defp executor_name(core) do
    case resolve_name(core) do
      name when is_atom(name) -> :"#{name}.Executor"
      _ -> Kyber.Effect.Executor
    end
  end

  defp plugin_manager_name(core) do
    case resolve_name(core) do
      name when is_atom(name) -> :"#{name}.PluginManager"
      _ -> Kyber.Plugin.Manager
    end
  end

  defp task_supervisor_name(core) do
    case resolve_name(core) do
      name when is_atom(name) -> :"#{name}.TaskSupervisor"
      _ -> Kyber.Effect.TaskSupervisor
    end
  end
end
