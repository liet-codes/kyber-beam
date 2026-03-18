defmodule Kyber.StateTest do
  use ExUnit.Case, async: true

  alias Kyber.State

  setup do
    {:ok, pid} = State.start()
    on_exit(fn -> if Process.alive?(pid), do: State.stop(pid) end)
    {:ok, state: pid}
  end

  test "initial state has empty sessions, plugins, errors", %{state: pid} do
    s = State.get(pid)
    assert s.sessions == %{}
    assert s.plugins == []
    assert s.errors == []
  end

  test "get/1 returns current state", %{state: pid} do
    s = State.get(pid)
    assert %State{} = s
  end

  test "update/2 applies a function to state", %{state: pid} do
    State.update(pid, fn s -> %{s | plugins: ["plugin_a"]} end)
    s = State.get(pid)
    assert s.plugins == ["plugin_a"]
  end

  test "add_plugin/2 prepends a plugin name", %{state: _pid} do
    s = %State{} |> State.add_plugin("plugin_x") |> State.add_plugin("plugin_y")
    assert "plugin_y" in s.plugins
    assert "plugin_x" in s.plugins
  end

  test "add_error/2 appends an error", %{state: _pid} do
    s = %State{} |> State.add_error(%{code: 500}) |> State.add_error(%{code: 404})
    assert length(s.errors) == 2
    assert List.last(s.errors) == %{code: 404}
  end

  test "put_session/3 inserts a session", %{state: _pid} do
    s = State.put_session(%State{}, "session-1", %{user: "myk"})
    assert Map.get(s.sessions, "session-1") == %{user: "myk"}
  end

  test "multiple updates accumulate", %{state: pid} do
    State.update(pid, &State.add_plugin(&1, "p1"))
    State.update(pid, &State.add_plugin(&1, "p2"))
    State.update(pid, &State.add_error(&1, %{msg: "oops"}))

    s = State.get(pid)
    assert length(s.plugins) == 2
    assert length(s.errors) == 1
  end

  test "start_link creates a named agent" do
    name = :"test_state_#{:rand.uniform(999_999)}"
    {:ok, pid} = State.start_link(name: name)
    s = State.get(pid)
    assert %State{} = s
    State.stop(pid)
  end
end
