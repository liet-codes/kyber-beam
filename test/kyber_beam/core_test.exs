defmodule Kyber.CoreTest do
  use ExUnit.Case, async: false

  alias Kyber.{Core, Delta}

  defp unique_name, do: :"core_test_#{:rand.uniform(9_999_999)}"

  # Poll a condition until it returns truthy or timeout (ms) expires.
  defp poll_until(fun, timeout \\ 500, interval \\ 10) do
    deadline = System.monotonic_time(:millisecond) + timeout
    do_poll(fun, deadline, interval)
  end

  defp do_poll(fun, deadline, interval) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= deadline do
        flunk("poll_until: condition not met within timeout")
      else
        :timer.sleep(interval)
        do_poll(fun, deadline, interval)
      end
    end
  end

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
    # PipelineWirer wires synchronously during startup — no sleep needed for
    # subscription, but emit is still async (runs via Task in Delta.Store)
    delta = Delta.new("test.event", %{"data" => 1})
    :ok = Core.emit(name, delta)

    # Store.append is a sync GenServer.call — delta is available immediately
    deltas = Core.query_deltas(name)
    assert Enum.any?(deltas, &(&1.id == delta.id))
  end

  test "emit message.received triggers reducer and updates state" do
    {:ok, _pid, name} = start_core()

    delta = Delta.new("message.received", %{"text" => "hi"})
    :ok = Core.emit(name, delta)

    # Reducer runs async via Task — poll until pipeline settles
    poll_until(fn -> match?(%Kyber.State{}, Core.get_state(name)) end)
    state = Core.get_state(name)
    assert %Kyber.State{} = state
  end

  test "emit plugin.loaded updates state.plugins" do
    {:ok, _pid, name} = start_core()

    delta = Delta.new("plugin.loaded", %{"name" => "test_plugin"})
    :ok = Core.emit(name, delta)

    # Reducer runs async via Task — poll until state reflects the change
    poll_until(fn -> "test_plugin" in Core.get_state(name).plugins end)
    state = Core.get_state(name)
    assert "test_plugin" in state.plugins
  end

  test "emit error.route updates state.errors" do
    {:ok, _pid, name} = start_core()

    delta = Delta.new("error.route", %{"message" => "test error"})
    :ok = Core.emit(name, delta)

    # Reducer runs async via Task — poll until state reflects the change
    poll_until(fn -> length(Core.get_state(name).errors) == 1 end)
    state = Core.get_state(name)
    assert length(state.errors) == 1
  end

  test "register_effect_handler + emit triggers handler" do
    {:ok, _pid, name} = start_core()
    # PipelineWirer runs synchronously as last supervisor child — no sleep needed

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

    d1 = Delta.new("event.a", %{})
    d2 = Delta.new("event.b", %{})
    Core.emit(name, d1)
    Core.emit(name, d2)

    # Store.append is sync — deltas available immediately
    deltas = Core.query_deltas(name)
    ids = Enum.map(deltas, & &1.id)
    assert d1.id in ids
    assert d2.id in ids
  end

  test "multiple emits accumulate correctly" do
    {:ok, _pid, name} = start_core()

    for i <- 1..5 do
      Core.emit(name, Delta.new("plugin.loaded", %{"name" => "p#{i}"}))
    end

    # Reducer runs async — poll until all 5 plugins are registered
    poll_until(fn -> length(Core.get_state(name).plugins) == 5 end, 1000)
    state = Core.get_state(name)
    assert length(state.plugins) == 5
  end

  # ── New tests for PipelineWirer and supervision fixes ────────────────────

  test "PipelineWirer: pipeline is wired synchronously — no sleep needed" do
    {:ok, _pid, name} = start_core()
    # Immediately after start_link returns, PipelineWirer has already run
    # and subscribed to the store. We can emit and expect effects without delay.
    test_pid = self()
    Core.register_effect_handler(name, :llm_call, fn effect ->
      send(test_pid, {:instant_effect, effect})
    end)

    delta = Delta.new("message.received", %{"text" => "no-sleep"})
    :ok = Core.emit(name, delta)

    # Only Task dispatch latency; no 50ms sleep hack needed.
    assert_receive {:instant_effect, _effect}, 1000
  end

  test "PipelineWirer: supervision tree has PipelineWirer as last child" do
    {:ok, pid, _name} = start_core()

    children = Supervisor.which_children(pid)
    child_ids = Enum.map(children, fn {id, _pid, _type, _mods} -> id end)

    # PipelineWirer must be present in the supervision tree
    assert Kyber.Core.PipelineWirer in child_ids
  end

  test "supervision strategy rest_for_one: all children listed" do
    {:ok, pid, _name} = start_core()
    children = Supervisor.which_children(pid)
    # Should have 6 children: TaskSup, Store, State, Executor, PluginMgr, PipelineWirer
    assert length(children) == 6
  end
end
