defmodule Kyber.Deployment do
  @moduledoc """
  Hot code deployment for Kyber clusters.

  Provides basic hot-reload capabilities across a cluster of BEAM nodes.
  This is a sketch/prototype — useful for development and local Mac Mini
  clusters but not production-hardened.

  ## Usage

      # Reload a single module on the current node
      Kyber.Deployment.reload_module(MyModule)

      # Reload on all connected Distribution nodes
      Kyber.Deployment.reload_cluster(MyModule)

      # Pull a git ref, compile, and reload changed modules
      Kyber.Deployment.deploy("main")
      Kyber.Deployment.deploy("v1.2.3")

  ## How it works

  - `reload_module/1`: Calls `:code.purge/1` then `:code.load_file/1`
    to hot-swap the BEAM bytecode in memory.
  - `reload_cluster/1`: Uses `:erpc.multicall/4` to run the reload on
    all nodes connected via `Kyber.Distribution`.
  - `deploy/1`: Runs `git fetch && git checkout <ref>`, calls `mix compile`,
    then reloads all modules that changed (detected via beam file mtimes).

  Deployed versions are tracked in the GenServer state for introspection.
  """

  use GenServer
  require Logger

  @type module_name :: module()
  @type git_ref :: String.t()
  @type version_info :: %{
          module: module_name(),
          loaded_at: integer(),
          node: atom()
        }

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the Deployment GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reload a single module on the current node.

  Purges the old code and loads the `.beam` file from disk.
  Returns `:ok` or `{:error, reason}`.
  """
  @spec reload_module(GenServer.server(), module_name()) :: :ok | {:error, any()}
  def reload_module(server \\ __MODULE__, module) when is_atom(module) do
    GenServer.call(server, {:reload_module, module})
  end

  @doc """
  Reload a module on all nodes connected via `Kyber.Distribution`.

  Uses `:erpc.multicall` for cluster-wide hot-swap.
  Returns a map of node → result.
  """
  @spec reload_cluster(GenServer.server(), module_name()) :: %{atom() => :ok | {:error, any()}}
  def reload_cluster(server \\ __MODULE__, module) when is_atom(module) do
    GenServer.call(server, {:reload_cluster, module}, 30_000)
  end

  @doc """
  Pull a git ref, compile, and reload all changed modules.

  `git_ref` can be a branch, tag, or commit SHA.
  Runs in the current working directory (assumes it's a git repo).
  Returns `{:ok, [modules]}` or `{:error, reason}`.
  """
  @spec deploy(GenServer.server(), git_ref()) :: {:ok, [module_name()]} | {:error, any()}
  def deploy(server \\ __MODULE__, git_ref) when is_binary(git_ref) do
    GenServer.call(server, {:deploy, git_ref}, 120_000)
  end

  @doc "List recently deployed module versions."
  @spec deployed_versions(GenServer.server()) :: [version_info()]
  def deployed_versions(server \\ __MODULE__) do
    GenServer.call(server, :deployed_versions)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    project_dir = Keyword.get(opts, :project_dir, File.cwd!())

    {:ok,
     %{
       deployed: [],
       project_dir: project_dir
     }}
  end

  @impl true
  def handle_call({:reload_module, module}, _from, state) do
    result = do_reload_module(module)

    new_state =
      case result do
        :ok ->
          version = %{
            module: module,
            loaded_at: System.system_time(:millisecond),
            node: node()
          }

          %{state | deployed: [version | Enum.take(state.deployed, 99)]}

        _ ->
          state
      end

    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:reload_cluster, module}, _from, state) do
    local_result = do_reload_module(module)

    # Reload on remote nodes
    remote_nodes = get_distribution_nodes()

    remote_results =
      if remote_nodes == [] do
        %{}
      else
        try do
          results = :erpc.multicall(remote_nodes, __MODULE__, :reload_module, [module], 15_000)

          Enum.zip(remote_nodes, results)
          |> Enum.map(fn {node_name, result} ->
            {node_name, unwrap_erpc_result(result)}
          end)
          |> Map.new()
        rescue
          e ->
            Logger.error("[Kyber.Deployment] cluster reload error: #{inspect(e)}")
            Map.new(remote_nodes, fn n -> {n, {:error, :rpc_failed}} end)
        end
      end

    all_results = Map.put(remote_results, node(), local_result)
    {:reply, all_results, state}
  end

  @impl true
  def handle_call({:deploy, git_ref}, _from, state) do
    Logger.info("[Kyber.Deployment] deploying #{git_ref}")

    with :ok <- git_fetch_and_checkout(git_ref, state.project_dir),
         {:ok, changed_modules} <- mix_compile(state.project_dir),
         reloaded <- reload_changed_modules(changed_modules) do
      Logger.info(
        "[Kyber.Deployment] deployed #{git_ref}, reloaded #{length(reloaded)} modules"
      )

      {:reply, {:ok, reloaded}, state}
    else
      {:error, reason} = err ->
        Logger.error("[Kyber.Deployment] deploy failed: #{inspect(reason)}")
        {:reply, err, state}
    end
  end

  @impl true
  def handle_call(:deployed_versions, _from, state) do
    {:reply, state.deployed, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp do_reload_module(module) do
    Logger.info("[Kyber.Deployment] reloading #{module}")

    # Purge old version and load from disk
    :code.purge(module)

    case :code.load_file(module) do
      {:module, ^module} ->
        Logger.info("[Kyber.Deployment] reloaded #{module}")
        :ok

      {:error, reason} ->
        Logger.error("[Kyber.Deployment] failed to reload #{module}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp get_distribution_nodes do
    try do
      Kyber.Distribution.nodes()
    rescue
      _ -> []
    end
  end

  defp git_fetch_and_checkout(git_ref, project_dir) do
    with {_, 0} <- System.cmd("git", ["fetch", "--all"], cd: project_dir, stderr_to_stdout: true),
         {_, 0} <- System.cmd("git", ["checkout", git_ref], cd: project_dir, stderr_to_stdout: true) do
      :ok
    else
      {output, code} ->
        {:error, "git failed (exit #{code}): #{output}"}
    end
  end

  defp mix_compile(project_dir) do
    # Record beam file mtimes before compile
    before_mtimes = beam_file_mtimes(project_dir)

    case System.cmd("mix", ["compile"], cd: project_dir, stderr_to_stdout: true) do
      {_output, 0} ->
        after_mtimes = beam_file_mtimes(project_dir)
        changed = find_changed_modules(before_mtimes, after_mtimes)
        {:ok, changed}

      {output, code} ->
        {:error, "mix compile failed (exit #{code}): #{output}"}
    end
  end

  defp beam_file_mtimes(project_dir) do
    beam_dir = Path.join([project_dir, "_build", "dev", "lib", "kyber_beam", "ebin"])

    case File.ls(beam_dir) do
      {:ok, files} ->
        files
        |> Enum.filter(&String.ends_with?(&1, ".beam"))
        |> Enum.map(fn file ->
          path = Path.join(beam_dir, file)
          mtime = File.stat!(path).mtime
          {file, mtime}
        end)
        |> Map.new()

      {:error, _} ->
        %{}
    end
  end

  defp find_changed_modules(before, after_mtimes) do
    Enum.flat_map(after_mtimes, fn {file, mtime} ->
      old_mtime = Map.get(before, file)

      if old_mtime != mtime do
        module_name = beam_file_to_module(file)
        if module_name, do: [module_name], else: []
      else
        []
      end
    end)
  end

  defp beam_file_to_module(file) do
    module_str = file |> String.replace_suffix(".beam", "")

    try do
      String.to_existing_atom("Elixir." <> module_str)
    rescue
      ArgumentError -> nil
    end
  end

  defp reload_changed_modules(modules) do
    Enum.filter(modules, fn module ->
      case do_reload_module(module) do
        :ok -> true
        _ -> false
      end
    end)
  end

  defp unwrap_erpc_result({:ok, value}), do: value
  defp unwrap_erpc_result({:error, _} = err), do: err
  defp unwrap_erpc_result(other), do: {:error, other}
end
