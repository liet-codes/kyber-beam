defmodule Kyber.Plugin.Manager do
  @moduledoc """
  DynamicSupervisor that manages plugin lifecycle.

  Each plugin runs as an isolated child process. If a plugin crashes,
  it crashes independently without affecting the rest of the system.

  Plugin modules must implement:
  - `child_spec/1` or `start_link/1`
  - `name/0 :: String.t()` — unique plugin identifier

  ## Usage

      {:ok, sup} = Kyber.Plugin.Manager.start_link()
      {:ok, pid} = Kyber.Plugin.Manager.register(sup, MyPlugin)
      :ok = Kyber.Plugin.Manager.unregister(sup, "my_plugin")
      :ok = Kyber.Plugin.Manager.reload(sup, "my_plugin")
      ["my_plugin"] = Kyber.Plugin.Manager.list(sup)
  """

  use DynamicSupervisor
  require Logger

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Start the Plugin.Manager DynamicSupervisor."
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register (start) a plugin module under the supervisor.

  The plugin module must export `start_link/1`. We derive a name via
  `plugin_module.name/0` if available, otherwise the module name string.

  Returns `{:ok, pid}` or `{:error, reason}`.
  """
  @spec register(Supervisor.supervisor(), module()) :: {:ok, pid()} | {:error, any()}
  def register(supervisor_pid, plugin_module) do
    child_spec = plugin_child_spec(plugin_module)

    case DynamicSupervisor.start_child(supervisor_pid, child_spec) do
      {:ok, pid} ->
        Logger.info("[Kyber.Plugin.Manager] registered plugin: #{plugin_name(plugin_module)}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = err ->
        Logger.error("[Kyber.Plugin.Manager] failed to register #{inspect(plugin_module)}: #{inspect(reason)}")
        err
    end
  end

  @doc """
  Unregister (stop) a plugin by name.

  Finds the child process whose registered name matches and terminates it.
  Returns `:ok` if found, `{:error, :not_found}` otherwise.
  """
  @spec unregister(Supervisor.supervisor(), String.t()) :: :ok | {:error, :not_found}
  def unregister(supervisor_pid, name) when is_binary(name) do
    case find_child_pid(supervisor_pid, name) do
      {:ok, pid} ->
        :ok = DynamicSupervisor.terminate_child(supervisor_pid, pid)
        Logger.info("[Kyber.Plugin.Manager] unregistered plugin: #{name}")
        :ok

      :error ->
        {:error, :not_found}
    end
  end

  @doc """
  Reload a plugin by name — unregister it, then re-register by module.

  The module is looked up from the running child's registered name.
  You can also pass the module directly.
  """
  @spec reload(Supervisor.supervisor(), String.t() | module()) :: :ok | {:error, any()}
  def reload(supervisor_pid, plugin_module) when is_atom(plugin_module) do
    name = plugin_name(plugin_module)
    _ = unregister(supervisor_pid, name)

    case register(supervisor_pid, plugin_module) do
      {:ok, _pid} -> :ok
      err -> err
    end
  end

  def reload(supervisor_pid, name) when is_binary(name) do
    # For reload by name, we need the module. Look it up from the child registry.
    case find_child_module(supervisor_pid, name) do
      {:ok, module} -> reload(supervisor_pid, module)
      :error -> {:error, :not_found}
    end
  end

  @doc "List all running plugin names."
  @spec list(Supervisor.supervisor()) :: [String.t()]
  def list(supervisor_pid) do
    DynamicSupervisor.which_children(supervisor_pid)
    |> Enum.flat_map(fn {_id, pid, _type, [module]} ->
      if is_pid(pid) and is_atom(module) and module != :undefined do
        [plugin_name(module)]
      else
        []
      end
    end)
  end

  # ── DynamicSupervisor callbacks ───────────────────────────────────────────

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp plugin_name(module) when is_atom(module) do
    if function_exported?(module, :name, 0) do
      module.name()
    else
      module |> to_string() |> String.replace("Elixir.", "")
    end
  end

  defp plugin_child_spec(module) do
    if function_exported?(module, :child_spec, 1) do
      module.child_spec([])
    else
      %{
        id: module,
        start: {module, :start_link, [[]]},
        restart: :transient
      }
    end
  end

  defp find_child_pid(supervisor_pid, name) do
    children = DynamicSupervisor.which_children(supervisor_pid)

    result =
      Enum.find(children, fn {_id, pid, _type, [module]} ->
        is_pid(pid) and is_atom(module) and plugin_name(module) == name
      end)

    case result do
      {_id, pid, _type, _modules} -> {:ok, pid}
      nil -> :error
    end
  end

  defp find_child_module(supervisor_pid, name) do
    children = DynamicSupervisor.which_children(supervisor_pid)

    result =
      Enum.find(children, fn {_id, _pid, _type, [module]} ->
        is_atom(module) and plugin_name(module) == name
      end)

    case result do
      {_id, _pid, _type, [module]} -> {:ok, module}
      nil -> :error
    end
  end
end
