defmodule Kyber.Core do
  @moduledoc """
  Top-level supervisor that orchestrates all Kyber components.

  ## Supervision tree

      Kyber.Core (Supervisor, strategy: :rest_for_one)
      ├── Kyber.Effect.TaskSupervisor (Task.Supervisor — async effect tasks)
      ├── Kyber.Delta.Store           (GenServer — persists/broadcasts deltas)
      ├── Kyber.State                 (Agent — holds application state)
      ├── Kyber.Effect.Executor       (GenServer — dispatches effects)
      ├── Kyber.Plugin.Manager        (DynamicSupervisor — plugin lifecycle)
      └── Kyber.Core.PipelineWirer    (GenServer — wires store→reducer→executor)

  The `:rest_for_one` strategy ensures that if an early child crashes, all
  children started after it are also restarted, preventing stale subscriptions.

  `PipelineWirer` is the last child: when its `init/1` runs, all prior siblings
  are guaranteed to be started and registered by name — no sleep hack needed.

  ## Data flow

      emit(delta)
        → Delta.Store.append        (persist + broadcast)
        → subscriber callback       (registered by PipelineWirer.init)
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

    if persist_delta?(delta) do
      Kyber.Delta.Store.append(store, delta)
    else
      # Ephemeral deltas skip disk persistence but still broadcast to
      # subscribers (PipelineWirer → reducer → effects). This keeps the
      # pipeline live without bloating the JSONL log.
      Kyber.Delta.Store.broadcast_only(store, delta)
    end
  end

  # Deltas that should NOT be persisted to the JSONL store.
  # cron.fired deltas accumulate at ~2.6/sec and overwhelm the store
  # (400K+ in 42 hours). They still need to reach the reducer for
  # heartbeat triggers, so we broadcast without writing to disk.
  @ephemeral_kinds ~w(cron.fired)
  defp persist_delta?(%Kyber.Delta{kind: kind}), do: kind not in @ephemeral_kinds

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

    # Plugins to start through Plugin.Manager at init — passed from Application.
    # Each entry is {module, opts} or just module (opts defaults to []).
    initial_plugins = Keyword.get(opts, :plugins, [])

    children = [
      # Task.Supervisor must be first — Delta.Store and Executor depend on it.
      {Task.Supervisor, name: task_sup},
      {Kyber.Delta.Store, [name: store, path: store_path, task_supervisor: task_sup]},
      {Kyber.State, [name: state]},
      {Kyber.Effect.Executor, [name: executor, task_supervisor: task_sup]},
      # Plugin.Manager starts after Executor so plugins can register effect
      # handlers immediately. Pass initial_plugins so they start via Manager
      # rather than being direct Application supervisor children.
      {Kyber.Plugin.Manager, [name: plugin_mgr, plugins: initial_plugins, core: core_name]},
      # PipelineWirer MUST be last: all prior siblings are guaranteed started
      # when its init/1 runs, so the subscribe call succeeds without any sleep.
      {Kyber.Core.PipelineWirer,
       [core_name: core_name, store: store, state: state, executor: executor]}
    ]

    # :rest_for_one ensures that if an early child (e.g. Delta.Store) crashes,
    # all children started after it also restart, preventing stale subscriptions.
    # Raised max_restarts to avoid silent supervisor death during debugging.
    Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 30)
  end

  # ── Private ───────────────────────────────────────────────────────────────

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
