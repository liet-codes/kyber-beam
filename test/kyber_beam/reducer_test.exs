defmodule Kyber.ReducerTest do
  use ExUnit.Case, async: true

  alias Kyber.{Delta, Reducer, State}

  defp empty_state, do: %State{}

  test "message.received emits :annotate_prompt effect (input saturation)" do
    delta = Delta.new("message.received", %{"text" => "hi"})
    {_state, effects} = Reducer.reduce(empty_state(), delta)

    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :annotate_prompt
    assert effect.delta_id == delta.id
    assert effect.payload["text"] == "hi"
  end

  test "message.received does NOT emit :llm_call directly (old chain broken)" do
    delta = Delta.new("message.received", %{"text" => "hi"})
    {_state, effects} = Reducer.reduce(empty_state(), delta)

    types = Enum.map(effects, & &1.type)
    refute :llm_call in types, "expected the LLM call to be deferred to prompt.annotated"
  end

  test "prompt.annotated emits :llm_call effect" do
    delta =
      Delta.new(
        "prompt.annotated",
        %{"text" => "hi", "annotations" => %{}},
        {:channel, "discord", "ch_1", "u_1"},
        "parent-msg-id"
      )

    {_state, effects} = Reducer.reduce(empty_state(), delta)

    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :llm_call
    assert effect.delta_id == delta.id
    assert effect.payload["text"] == "hi"
    assert effect.origin == {:channel, "discord", "ch_1", "u_1"}
  end

  test "prompt.annotated does not change state" do
    state = empty_state()
    delta = Delta.new("prompt.annotated", %{"text" => "hi"})
    {new_state, _effects} = Reducer.reduce(state, delta)
    assert new_state == state
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

  # Phase 3 reducer tests

  test "cron.fired heartbeat emits :annotate_prompt effect" do
    state = empty_state()
    delta = Delta.new("cron.fired", %{"job_name" => "heartbeat"}, {:cron, "heartbeat"})
    {_state, effects} = Reducer.reduce(state, delta)

    assert length(effects) == 1
    assert hd(effects).type == :annotate_prompt
    refute Enum.any?(effects, &(&1.type == :llm_call))
  end

  test "cron.fired non-heartbeat emits no effects" do
    state = empty_state()
    delta = Delta.new("cron.fired", %{"job_name" => "daily-report"}, {:cron, "daily-report"})
    {_state, effects} = Reducer.reduce(state, delta)

    assert effects == []
  end

  test "familiard.escalation critical emits :annotate_prompt effect" do
    state = empty_state()
    delta = Delta.new("familiard.escalation", %{"level" => "critical", "message" => "down"})
    {_state, effects} = Reducer.reduce(state, delta)

    assert length(effects) == 1
    assert hd(effects).type == :annotate_prompt
    assert hd(effects).payload["text"] =~ "CRITICAL"
    refute Enum.any?(effects, &(&1.type == :llm_call))
  end

  test "familiard.escalation warning emits :annotate_prompt effect" do
    state = empty_state()
    delta = Delta.new("familiard.escalation", %{"level" => "warning", "message" => "slow"})
    {_state, effects} = Reducer.reduce(state, delta)

    assert length(effects) == 1
    assert hd(effects).type == :annotate_prompt
    refute Enum.any?(effects, &(&1.type == :llm_call))
  end

  test "familiard.escalation info emits no effects" do
    state = empty_state()
    delta = Delta.new("familiard.escalation", %{"level" => "info", "message" => "all good"})
    {_state, effects} = Reducer.reduce(state, delta)

    assert effects == []
  end

  test "task.result emits no effects and does not change state" do
    state = empty_state()
    delta = Delta.new("task.result", %{
      "task_id" => "abc123",
      "task_name" => "echo",
      "result" => %{"hello" => "world"}
    })
    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert effects == []
  end

  test "task.error emits no effects and does not change state" do
    state = empty_state()
    delta = Delta.new("task.error", %{
      "task_id" => "abc123",
      "task_name" => "fail",
      "reason" => "intentional failure"
    })
    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert effects == []
  end

  test "voice.audio emits no effects and does not change state" do
    state = empty_state()
    delta = Delta.new("voice.audio", %{"audio" => "base64data", "encoding" => "mp3"})
    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert effects == []
  end

  # ── Delta-routed memory writes ─────────────────────────────────────────

  test "memory.add emits vault_write effect with correct path/content" do
    state = empty_state()
    delta = Delta.new("memory.add", %{
      "path" => "people/myk.md",
      "content" => "# Myk\nSoftware engineer.",
      "reason" => "Extracted from conversation"
    })
    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :vault_write
    assert effect.path == "people/myk.md"
    assert effect.content == "# Myk\nSoftware engineer."
    assert effect.reason == "Extracted from conversation"
  end

  test "memory.update emits vault_write effect" do
    state = empty_state()
    delta = Delta.new("memory.update", %{
      "path" => "people/myk.md",
      "content" => "# Myk\nUpdated info.",
      "reason" => "Updated preference"
    })
    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :vault_write
    assert effect.path == "people/myk.md"
    assert effect.content == "# Myk\nUpdated info."
    assert effect.reason == "Updated preference"
  end

  test "memory.delete emits vault_delete effect" do
    state = empty_state()
    delta = Delta.new("memory.delete", %{
      "path" => "people/old-contact.md",
      "reason" => "No longer relevant"
    })
    {new_state, effects} = Reducer.reduce(state, delta)

    assert new_state == state
    assert length(effects) == 1
    effect = hd(effects)
    assert effect.type == :vault_delete
    assert effect.path == "people/old-contact.md"
    assert effect.reason == "No longer relevant"
  end

  test "vault.written and vault.deleted are informational (no effects)" do
    state = empty_state()

    d1 = Delta.new("vault.written", %{"path" => "people/myk.md", "ts" => 123})
    {s1, e1} = Reducer.reduce(state, d1)
    assert s1 == state
    assert e1 == []

    d2 = Delta.new("vault.deleted", %{"path" => "people/old.md", "ts" => 456})
    {s2, e2} = Reducer.reduce(state, d2)
    assert s2 == state
    assert e2 == []
  end
end
