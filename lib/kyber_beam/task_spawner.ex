defmodule Kyber.TaskSpawner do
  @moduledoc """
  Handles `:spawn_task` effects by spawning supervised tasks and emitting
  result deltas back through the delta store.

  ## Flow

  1. Receives a `:spawn_task` effect from the executor
  2. Generates a unique `task_id`
  3. Looks up the task function in `Kyber.TaskRegistry`
  4. Spawns a supervised `Task` with timeout
  5. On success: emits `"task.result"` delta to `Kyber.Delta.Store`
  6. On failure: emits `"task.error"` delta to `Kyber.Delta.Store`

  ## Effect format

      %{
        type: :spawn_task,
        payload: %{
          "task_name" => "echo",
          "task_params" => %{"key" => "value"},
          "timeout_ms" => 5000
        }
      }

  ## Usage

  Register the handler with the effect executor:

      handler = Kyber.TaskSpawner.build_handler(
        task_registry: Kyber.TaskRegistry,
        delta_store: Kyber.Delta.Store,
        task_supervisor: Kyber.Effect.TaskSupervisor
      )
      Kyber.Effect.Executor.register(executor, :spawn_task, handler)
  """

  require Logger

  @default_timeout_ms 30_000

  @doc """
  Build a handler function for `:spawn_task` effects.

  Options:
  - `:task_registry` — pid/name of `Kyber.TaskRegistry` (required)
  - `:delta_store` — pid/name of `Kyber.Delta.Store` (required)
  - `:task_supervisor` — pid/name of `Task.Supervisor` (required)
  """
  @spec build_handler(keyword()) :: (map() -> any())
  def build_handler(opts) do
    registry = Keyword.fetch!(opts, :task_registry)
    store = Keyword.fetch!(opts, :delta_store)
    task_sup = Keyword.fetch!(opts, :task_supervisor)

    fn effect ->
      spawn_task(effect, registry, store, task_sup)
    end
  end

  @doc """
  Spawn a task from an effect. Returns `{:ok, task_id}` or `{:error, reason}`.

  This is the core logic, also useful for direct invocation in tests.
  """
  @spec spawn_task(map(), GenServer.server(), GenServer.server(), GenServer.server()) ::
          {:ok, String.t()} | {:error, atom() | String.t()}
  def spawn_task(effect, registry, store, task_sup) do
    payload = Map.get(effect, :payload) || Map.get(effect, "payload", %{})
    task_name = Map.get(payload, "task_name") || Map.get(payload, :task_name)
    task_params = Map.get(payload, "task_params") || Map.get(payload, :task_params, %{})
    timeout_ms = Map.get(payload, "timeout_ms") || Map.get(payload, :timeout_ms, @default_timeout_ms)

    task_id = generate_task_id()

    case Kyber.TaskRegistry.lookup(registry, task_name) do
      {:ok, fun} ->
        Logger.info("[Kyber.TaskSpawner] spawning task #{task_name} (#{task_id}), timeout=#{timeout_ms}ms")

        Task.Supervisor.start_child(task_sup, fn ->
          run_task(fun, task_params, task_id, task_name, timeout_ms, store)
        end)

        {:ok, task_id}

      {:error, :not_found} ->
        Logger.warning("[Kyber.TaskSpawner] unknown task: #{task_name}")
        emit_error_delta(store, task_id, task_name, "unknown task: #{task_name}")
        {:error, :unknown_task}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp run_task(fun, params, task_id, task_name, timeout_ms, store) do
    # Run in a separate process so crashes don't kill us
    caller = self()
    ref = make_ref()

    pid = spawn(fn ->
      try do
        result = fun.(params)
        send(caller, {ref, {:ok, result}})
      rescue
        e ->
          send(caller, {ref, {:error, Exception.message(e)}})
      catch
        kind, reason ->
          send(caller, {ref, {:error, "#{kind}: #{inspect(reason)}"}})
      end
    end)

    Process.monitor(pid)

    receive do
      {^ref, {:ok, result}} ->
        emit_result_delta(store, task_id, task_name, result)

      {^ref, {:error, reason}} ->
        Logger.warning("[Kyber.TaskSpawner] task #{task_name} (#{task_id}) failed: #{reason}")
        emit_error_delta(store, task_id, task_name, reason)

      {:DOWN, _mref, :process, ^pid, reason} when reason != :normal ->
        Logger.warning("[Kyber.TaskSpawner] task #{task_name} (#{task_id}) crashed: #{inspect(reason)}")
        emit_error_delta(store, task_id, task_name, inspect(reason))
    after
      timeout_ms ->
        Process.exit(pid, :kill)
        Logger.warning("[Kyber.TaskSpawner] task #{task_name} (#{task_id}) timed out")
        emit_error_delta(store, task_id, task_name, "timeout after #{timeout_ms}ms")
    end
  end

  defp emit_result_delta(store, task_id, task_name, result) do
    delta = Kyber.Delta.new(
      "task.result",
      %{
        "task_id" => task_id,
        "task_name" => task_name,
        "result" => serialize_result(result)
      },
      {:system, "task_spawner"}
    )

    Kyber.Delta.Store.append(store, delta)
    Logger.info("[Kyber.TaskSpawner] task #{task_name} (#{task_id}) completed")
  end

  defp emit_error_delta(store, task_id, task_name, reason) do
    delta = Kyber.Delta.new(
      "task.error",
      %{
        "task_id" => task_id,
        "task_name" => task_name,
        "reason" => reason
      },
      {:system, "task_spawner"}
    )

    Kyber.Delta.Store.append(store, delta)
    Logger.warning("[Kyber.TaskSpawner] task #{task_name} (#{task_id}) failed: #{reason}")
  end

  defp generate_task_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  # Ensure result is JSON-serializable
  defp serialize_result(result) when is_map(result), do: result
  defp serialize_result(result) when is_binary(result), do: result
  defp serialize_result(result) when is_number(result), do: result
  defp serialize_result(result) when is_boolean(result), do: result
  defp serialize_result(result) when is_nil(result), do: nil
  defp serialize_result(result) when is_list(result), do: result
  defp serialize_result(result), do: inspect(result)
end
