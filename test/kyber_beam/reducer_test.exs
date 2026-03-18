defmodule Kyber.ReducerTest do
  use ExUnit.Case, async: true

  alias Kyber.{Delta, Reducer, State}

  defp empty_state, do: %State{}

  test "message.received emits :llm_call effect" do
    delta = Delta.new("message.received", %{"text" => "hi"})
    {_state, effects} = Reducer.reduce(empty_state(), delta)

    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :llm_call
    assert effect.delta_id == delta.id
  end

  test "message.received does not change state" do
    state = empty_state()
    delta = Delta.new("message.received", %{})
    {new_state, _effects} = Reducer.reduce(state, delta)
    assert new_state == state
  end

  test "error.route appends to state.errors" do
    state = empty_state()
    delta = Delta.new("error.route", %{"message" => "something broke"})
    {new_state, effects} = Reducer.reduce(state, delta)

    assert effects == []
    assert length(new_state.errors) == 1
    error = hd(new_state.errors)
    assert error.delta_id == delta.id
  end

  test "error.route accumulates multiple errors" do
    state = empty_state()
    d1 = Delta.new("error.route", %{"n" => 1})
    d2 = Delta.new("error.route", %{"n" => 2})
    {s1, _} = Reducer.reduce(state, d1)
    {s2, _} = Reducer.reduce(s1, d2)
    assert length(s2.errors) == 2
  end

  test "plugin.loaded adds plugin name to state.plugins" do
    state = empty_state()
    delta = Delta.new("plugin.loaded", %{"name" => "my_plugin"})
    {new_state, effects} = Reducer.reduce(state, delta)

    assert effects == []
    assert "my_plugin" in new_state.plugins
  end

  test "plugin.loaded handles atom :name key" do
    state = empty_state()
    delta = Delta.new("plugin.loaded", %{name: "atom_plugin"})
    {new_state, _} = Reducer.reduce(state, delta)
    assert "atom_plugin" in new_state.plugins
  end

  test "unknown kind returns unchanged state and no effects" do
    state = empty_state()
    delta = Delta.new("some.unknown.event", %{"data" => 42})
    {new_state, effects} = Reducer.reduce(state, delta)
    assert new_state == state
    assert effects == []
  end

  test "llm.response with discord channel origin emits :send_message effect" do
    state = empty_state()
    delta = Delta.new(
      "llm.response",
      %{"content" => "Here is your answer", "model" => "claude-sonnet-4-6"},
      {:channel, "discord", "ch_999", "user_1"}
    )

    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :send_message
    assert effect.payload["channel_id"] == "ch_999"
    assert effect.payload["content"] == "Here is your answer"
  end

  test "llm.response with non-channel origin emits no effects" do
    state = empty_state()
    delta = Delta.new(
      "llm.response",
      %{"content" => "some content"},
      {:system, "internal"}
    )

    {_state, effects} = Reducer.reduce(state, delta)
    assert effects == []
  end

  test "llm.response with empty content emits no effects" do
    state = empty_state()
    delta = Delta.new(
      "llm.response",
      %{"content" => ""},
      {:channel, "discord", "ch_1", "u_1"}
    )

    {_state, effects} = Reducer.reduce(state, delta)
    assert effects == []
  end

  test "llm.error appends to state.errors" do
    state = empty_state()
    delta = Delta.new("llm.error", %{"error" => "rate limited", "status" => 429})
    {new_state, effects} = Reducer.reduce(state, delta)

    assert effects == []
    assert length(new_state.errors) == 1
    error = hd(new_state.errors)
    assert error.delta_id == delta.id
    assert error.kind == "llm.error"
  end

  test "llm.error accumulates multiple errors" do
    state = empty_state()
    d1 = Delta.new("llm.error", %{"error" => "first"})
    d2 = Delta.new("llm.error", %{"error" => "second"})
    {s1, _} = Reducer.reduce(state, d1)
    {s2, _} = Reducer.reduce(s1, d2)
    assert length(s2.errors) == 2
  end

  test "reducer is pure — no side effects between calls" do
    state = empty_state()
    delta = Delta.new("message.received", %{})

    {s1, e1} = Reducer.reduce(state, delta)
    {s2, e2} = Reducer.reduce(state, delta)

    # Same input → same output
    assert s1 == s2
    assert length(e1) == length(e2)
    assert hd(e1).type == hd(e2).type
  end
end
