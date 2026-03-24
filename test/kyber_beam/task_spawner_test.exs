defmodule Kyber.TaskSpawnerTest do
  use ExUnit.Case, async: true

  alias Kyber.TaskSpawner
  alias Kyber.TaskRegistry
  alias Kyber.Delta.Store

  setup do
    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, registry} = TaskRegistry.start_link(name: nil)

    # Start a delta store — we need to capture emitted deltas
    dir = System.tmp_dir!() |> Path.join("kyber_task_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    {:ok, store} = Store.start_link(data_dir: dir, name: nil)

    on_exit(fn ->
      for pid <- [task_sup, registry, store] do
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end
      File.rm_rf(dir)
    end)

    {:ok, task_sup: task_sup, registry: registry, store: store}
  end

  describe "spawn_task — success" do
    test "echo task returns params as result delta", ctx do
      test_pid = self()

      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      effect = %{
        type: :spawn_task,
        payload: %{
          "task_name" => "echo",
          "task_params" => %{"hello" => "world"},
          "timeout_ms" => 5000
        }
      }

      {:ok, task_id} = TaskSpawner.spawn_task(effect, ctx.registry, ctx.store, ctx.task_sup)
      assert is_binary(task_id)
      assert byte_size(task_id) == 16  # 8 bytes hex-encoded

      assert_receive {:delta, %Kyber.Delta{kind: "task.result"} = delta}, 2000
      assert delta.payload["task_id"] == task_id
      assert delta.payload["task_name"] == "echo"
      assert delta.payload["result"] == %{"hello" => "world"}
    end
  end

  describe "spawn_task — failure" do
    test "failing task emits task.error delta", ctx do
      test_pid = self()

      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      effect = %{
        type: :spawn_task,
        payload: %{
          "task_name" => "fail",
          "task_params" => %{},
          "timeout_ms" => 5000
        }
      }

      {:ok, task_id} = TaskSpawner.spawn_task(effect, ctx.registry, ctx.store, ctx.task_sup)

      assert_receive {:delta, %Kyber.Delta{kind: "task.error"} = delta}, 2000
      assert delta.payload["task_id"] == task_id
      assert delta.payload["task_name"] == "fail"
      assert is_binary(delta.payload["reason"])
      assert String.contains?(delta.payload["reason"], "intentional task failure")
    end
  end

  describe "spawn_task — timeout" do
    test "task that exceeds timeout emits task.error", ctx do
      test_pid = self()

      # Register a slow task
      TaskRegistry.register(ctx.registry, "slow", fn _params ->
        # Simulates a long-running task — sleep is the task payload, not test timing
        Process.sleep(10_000)
        :done
      end)

      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      effect = %{
        type: :spawn_task,
        payload: %{
          "task_name" => "slow",
          "task_params" => %{},
          "timeout_ms" => 200
        }
      }

      {:ok, task_id} = TaskSpawner.spawn_task(effect, ctx.registry, ctx.store, ctx.task_sup)

      assert_receive {:delta, %Kyber.Delta{kind: "task.error"} = delta}, 3000
      assert delta.payload["task_id"] == task_id
      assert String.contains?(delta.payload["reason"], "timeout")
    end
  end

  describe "spawn_task — unknown task" do
    test "unknown task name emits error delta immediately", ctx do
      test_pid = self()

      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      effect = %{
        type: :spawn_task,
        payload: %{
          "task_name" => "nonexistent_task",
          "task_params" => %{},
          "timeout_ms" => 5000
        }
      }

      {:error, :unknown_task} =
        TaskSpawner.spawn_task(effect, ctx.registry, ctx.store, ctx.task_sup)

      assert_receive {:delta, %Kyber.Delta{kind: "task.error"} = delta}, 1000
      assert String.contains?(delta.payload["reason"], "unknown task")
    end
  end

  describe "spawn_task — concurrent tasks" do
    test "multiple tasks run concurrently and each emits its own result", ctx do
      test_pid = self()

      # Register a task that returns its name after a short delay
      TaskRegistry.register(ctx.registry, "identify", fn params ->
        # Simulates async work — sleep is the task payload, not test timing
        Process.sleep(50)
        %{"id" => params["id"]}
      end)

      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      # Spawn 3 concurrent tasks
      task_ids =
        for i <- 1..3 do
          effect = %{
            type: :spawn_task,
            payload: %{
              "task_name" => "identify",
              "task_params" => %{"id" => "task_#{i}"},
              "timeout_ms" => 5000
            }
          }

          {:ok, task_id} = TaskSpawner.spawn_task(effect, ctx.registry, ctx.store, ctx.task_sup)
          task_id
        end

      # Collect all 3 results
      results =
        for _ <- 1..3 do
          assert_receive {:delta, %Kyber.Delta{kind: "task.result"} = delta}, 3000
          delta
        end

      result_task_ids = Enum.map(results, & &1.payload["task_id"]) |> Enum.sort()
      assert result_task_ids == Enum.sort(task_ids)

      # Each result has the correct task name
      for delta <- results do
        assert delta.payload["task_name"] == "identify"
        assert is_map(delta.payload["result"])
      end
    end
  end

  describe "build_handler" do
    test "builds a handler compatible with Effect.Executor", ctx do
      handler = TaskSpawner.build_handler(
        task_registry: ctx.registry,
        delta_store: ctx.store,
        task_supervisor: ctx.task_sup
      )

      assert is_function(handler, 1)

      test_pid = self()
      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      effect = %{
        type: :spawn_task,
        payload: %{
          "task_name" => "echo",
          "task_params" => %{"via" => "handler"},
          "timeout_ms" => 5000
        }
      }

      {:ok, task_id} = handler.(effect)
      assert is_binary(task_id)

      assert_receive {:delta, %Kyber.Delta{kind: "task.result"} = delta}, 2000
      assert delta.payload["task_id"] == task_id
      assert delta.payload["result"]["via"] == "handler"
    end
  end

  describe "full loop — effect executor integration" do
    test "spawn_task via effect executor emits delta visible to next turn", ctx do
      # Set up a full executor + spawn_task handler
      {:ok, executor} =
        Kyber.Effect.Executor.start_link(
          task_supervisor: ctx.task_sup,
          name: nil
        )

      handler = TaskSpawner.build_handler(
        task_registry: ctx.registry,
        delta_store: ctx.store,
        task_supervisor: ctx.task_sup
      )

      Kyber.Effect.Executor.register(executor, :spawn_task, handler)

      test_pid = self()
      Store.subscribe(ctx.store, fn delta ->
        send(test_pid, {:delta, delta})
      end)

      # Execute the spawn_task effect through the executor
      effect = %{
        type: :spawn_task,
        payload: %{
          "task_name" => "echo",
          "task_params" => %{"loop_test" => true},
          "timeout_ms" => 5000
        }
      }

      {:ok, _ref} = Kyber.Effect.Executor.execute(executor, effect)

      # Wait for the task.result delta
      assert_receive {:delta, %Kyber.Delta{kind: "task.result"} = delta}, 3000
      assert delta.payload["result"]["loop_test"] == true

      # Verify it's stored in the delta store (visible to LLM in next turn)
      deltas = Store.query(ctx.store)
      matching = Enum.filter(deltas, fn d ->
        d.kind == "task.result" && d.payload["task_id"] == delta.payload["task_id"]
      end)
      assert length(matching) == 1

      GenServer.stop(executor, :normal, 500)
    end
  end
end
