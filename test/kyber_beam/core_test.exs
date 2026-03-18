defmodule Kyber.CoreTest do
  use ExUnit.Case, async: false

  alias Kyber.{Core, Delta}

  defp unique_name, do: :"core_test_#{:rand.uniform(9_999_999)}"

  defp start_core(extra_opts \\ []) do
    path = System.tmp_dir!() |> Path.join("kyber_core_test_#{:rand.uniform(999_999)}.jsonl")
    name = unique_name()
    opts = [name: name, store_path: path] ++ extra_opts
    {:ok, pid} = Core.start_link(opts)
    on_exit(fn ->
      try do
        if Process.alive?(pid), do: Supervisor.stop(pid, :normal, 1000)
      catch
        :exit, _ -> :ok
      end
      File.rm(path)
    end)
    {:ok, pid, name}
  end

  test "starts successfully and supervisor is alive" do
    {:ok, pid, _name} = start_core()
    assert Process.alive?(pid)
  end

  test "emit appends a delta to the store" do
    {:ok, _pid, name} = start_core()
    Process.sleep(100)  # let subscription wire up

    delta = Delta.new("test.event", %{"data" => 1})
    :ok = Core.emit(name, delta)
    Process.sleep(50)

    deltas = Core.query_deltas(name)
    assert Enum.any?(deltas, &(&1.id == delta.id))
  end

  test "emit message.received triggers reducer and updates state" do
    {:ok, _pid, name} = start_core()
    Process.sleep(100)

    delta = Delta.new("message.received", %{"text" => "hi"})
    :ok = Core.emit(name, delta)
    Process.sleep(100)

    # State should not change for message.received (no state change, only effect)
    state = Core.get_state(name)
    assert %Kyber.State{} = state
  end

  test "emit plugin.loaded updates state.plugins" do
    {:ok, _pid, name} = start_core()
    Process.sleep(100)

    delta = Delta.new("plugin.loaded", %{"name" => "test_plugin"})
    :ok = Core.emit(name, delta)
    Process.sleep(100)

    state = Core.get_state(name)
    assert "test_plugin" in state.plugins
  end

  test "emit error.route updates state.errors" do
    {:ok, _pid, name} = start_core()
    Process.sleep(100)

    delta = Delta.new("error.route", %{"message" => "test error"})
    :ok = Core.emit(name, delta)
    Process.sleep(100)

    state = Core.get_state(name)
    assert length(state.errors) == 1
  end

  test "register_effect_handler + emit triggers handler" do
    {:ok, _pid, name} = start_core()
    Process.sleep(150)  # let subscription wire up (wires at 50ms)

    test_pid = self()
    Core.register_effect_handler(name, :llm_call, fn effect ->
      send(test_pid, {:llm_called, effect})
    end)

    delta = Delta.new("message.received", %{"text" => "trigger"})
    :ok = Core.emit(name, delta)

    assert_receive {:llm_called, effect}, 2000
    assert effect.type == :llm_call
  end

  test "query_deltas returns stored deltas" do
    {:ok, _pid, name} = start_core()
    Process.sleep(100)

    d1 = Delta.new("event.a", %{})
    d2 = Delta.new("event.b", %{})
    Core.emit(name, d1)
    Core.emit(name, d2)
    Process.sleep(50)

    deltas = Core.query_deltas(name)
    ids = Enum.map(deltas, & &1.id)
    assert d1.id in ids
    assert d2.id in ids
  end

  test "multiple emits accumulate correctly" do
    {:ok, _pid, name} = start_core()
    Process.sleep(150)  # let subscription wire up

    for i <- 1..5 do
      Core.emit(name, Delta.new("plugin.loaded", %{"name" => "p#{i}"}))
    end

    Process.sleep(300)
    state = Core.get_state(name)
    assert length(state.plugins) == 5
  end
end
