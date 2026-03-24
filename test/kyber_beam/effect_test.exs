defmodule Kyber.EffectTest do
  use ExUnit.Case, async: true

  # Kyber.Effect struct was removed (P2-2). Effects are plain maps with :type.
  alias Kyber.Effect.Executor

  setup do
    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, pid} = Executor.start_link(task_supervisor: task_sup)
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
      catch
        :exit, _ -> :ok
      end
      try do
        if Process.alive?(task_sup), do: Supervisor.stop(task_sup, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)
    {:ok, executor: pid, task_sup: task_sup}
  end

  describe "Kyber.Effect.Executor — register" do
    test "register returns :ok", %{executor: pid} do
      assert Executor.register(pid, :test_effect, fn _ -> :ok end) == :ok
    end

    test "can register multiple effect types", %{executor: pid} do
      assert Executor.register(pid, :type_a, fn _ -> :a end) == :ok
      assert Executor.register(pid, :type_b, fn _ -> :b end) == :ok
    end

    test "re-registering overwrites handler", %{executor: pid} do
      Executor.register(pid, :my_type, fn _ -> :first end)
      assert Executor.register(pid, :my_type, fn _ -> :second end) == :ok
    end
  end

  describe "Kyber.Effect.Executor — string type safety" do
    test "unknown string type does not crash (DoS fix)", %{executor: pid} do
      # String.to_existing_atom was a crash vector for unknown atoms.
      # safe_to_atom now returns :unknown instead of raising ArgumentError.
      result = Executor.execute(pid, %{"type" => "totally_unknown_effect_xyz_abc_123"})
      # Returns :no_handler (not a crash), and executor stays alive
      assert result == {:error, :no_handler}
      assert Process.alive?(pid)
    end

    test "known string type is resolved correctly", %{executor: pid} do
      test_pid = self()
      Executor.register(pid, :llm_call, fn _effect -> send(test_pid, :ran) end)

      # String "llm_call" should resolve to :llm_call atom
      {:ok, _ref} = Executor.execute(pid, %{"type" => "llm_call"})
      assert_receive :ran, 500
    end
  end

  describe "Kyber.Effect.Executor — execute" do
    test "returns {:ok, ref} when handler is registered", %{executor: pid} do
      Executor.register(pid, :test_type, fn _ -> :handled end)
      result = Executor.execute(pid, %{type: :test_type})
      assert match?({:ok, _ref}, result)
    end

    test "returns {:error, :no_handler} for unregistered type", %{executor: pid} do
      result = Executor.execute(pid, %{type: :nonexistent_type})
      assert result == {:error, :no_handler}
    end

    test "handler actually runs asynchronously", %{executor: pid} do
      test_pid = self()
      Executor.register(pid, :async_test, fn effect ->
        send(test_pid, {:effect_ran, effect})
        :done
      end)

      {:ok, _ref} = Executor.execute(pid, %{type: :async_test, value: 42})
      assert_receive {:effect_ran, effect}, 1000
      assert effect.value == 42
    end

    test "handler error does not crash executor", %{executor: pid} do
      Executor.register(pid, :crash_type, fn _ -> raise "boom!" end)

      # Should not crash the executor
      {:ok, _ref} = Executor.execute(pid, %{type: :crash_type})

      # Executor is still alive and functional (poll until async handler completes)
      TestHelpers.eventually(fn ->
        assert Process.alive?(pid)
        # Verify executor is still responsive
        assert Executor.execute(pid, %{type: :nonexistent}) == {:error, :no_handler}
      end)
    end

    test "executes plain map effect (struct removed, P2-2)", %{executor: pid} do
      test_pid = self()
      Executor.register(pid, :effect_struct_test, fn _ ->
        send(test_pid, :ran)
      end)

      # Effects are plain maps with :type — no struct needed
      effect = %{type: :effect_struct_test}
      {:ok, _ref} = Executor.execute(pid, effect)
      assert_receive :ran, 500
    end
  end
end
