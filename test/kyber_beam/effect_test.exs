defmodule Kyber.EffectTest do
  use ExUnit.Case, async: true

  alias Kyber.Effect
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

  describe "Kyber.Effect" do
    test "new/2 creates an effect struct" do
      e = Effect.new(:llm_call, %{delta_id: "abc"})
      assert e.type == :llm_call
      assert e.data == %{delta_id: "abc"}
    end

    test "new/1 defaults data to empty map" do
      e = Effect.new(:llm_call)
      assert e.data == %{}
    end
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
      Process.sleep(100)

      # Executor is still alive and functional
      assert Process.alive?(pid)
      result = Executor.execute(pid, %{type: :nonexistent})
      assert result == {:error, :no_handler}
    end

    test "executes Kyber.Effect struct", %{executor: pid} do
      test_pid = self()
      Executor.register(pid, :effect_struct_test, fn _ ->
        send(test_pid, :ran)
      end)

      effect = Effect.new(:effect_struct_test, %{})
      {:ok, _ref} = Executor.execute(pid, effect)
      assert_receive :ran, 500
    end
  end
end
