defmodule Kyber.SessionTest do
  use ExUnit.Case, async: true

  alias Kyber.{Session, Delta}
  alias Kyber.Delta.Store

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_session(opts \\ []) do
    name = :"session_#{:rand.uniform(999_999)}"
    {:ok, pid} = Session.start_link([name: name] ++ opts)
    pid
  end

  defp start_store do
    path = System.tmp_dir!() |> Path.join("kyber_session_test_#{:rand.uniform(999_999)}.jsonl")
    {:ok, task_sup} = Task.Supervisor.start_link()
    {:ok, store} = Store.start_link(
      path: path,
      name: :"store_#{:rand.uniform(999_999)}",
      task_supervisor: task_sup
    )
    on_exit(fn ->
      File.rm(path)
      try do
        if Process.alive?(task_sup), do: Supervisor.stop(task_sup, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)
    {store, path}
  end

  # Start a fresh Session backed by a pre-populated store (for rehydration tests).
  # Returns {session_pid, store_pid}.
  defp session_with_store(deltas) do
    {store, _path} = start_store()
    Enum.each(deltas, &Store.append(store, &1))
    pid = start_session(delta_store: store)
    {pid, store}
  end

  defp sample_delta(kind \\ "message.received", text \\ "hello") do
    Delta.new(kind, %{"text" => text}, {:human, "user_1"})
  end

  defp human_delta(kind, payload, user_id) do
    Delta.new(kind, payload, {:human, user_id})
  end

  defp channel_delta(kind, payload, channel, chat_id, sender_id) do
    Delta.new(kind, payload, {:channel, channel, chat_id, sender_id})
  end

  defp system_delta(kind, payload) do
    Delta.new(kind, payload, {:system, "internal"})
  end

  # ── Basic session tests (no rehydration) ─────────────────────────────────

  test "get_history returns empty list for unknown chat_id" do
    pid = start_session()
    assert Session.get_history(pid, "nonexistent") == []
  end

  test "add_message stores a delta in the session history" do
    pid = start_session()
    delta = sample_delta()
    :ok = Session.add_message(pid, "chat_1", delta)
    history = Session.get_history(pid, "chat_1")
    assert length(history) == 1
    assert hd(history).id == delta.id
  end

  test "add_message appends in order" do
    pid = start_session()
    d1 = sample_delta("message.received", "first")
    d2 = sample_delta("message.received", "second")
    d3 = sample_delta("message.received", "third")

    Session.add_message(pid, "chat_1", d1)
    Session.add_message(pid, "chat_1", d2)
    Session.add_message(pid, "chat_1", d3)

    history = Session.get_history(pid, "chat_1")
    assert length(history) == 3
    assert Enum.map(history, & &1.id) == [d1.id, d2.id, d3.id]
  end

  test "different chat_ids have independent histories" do
    pid = start_session()
    d1 = sample_delta("message.received", "chat A message")
    d2 = sample_delta("message.received", "chat B message")

    Session.add_message(pid, "chat_A", d1)
    Session.add_message(pid, "chat_B", d2)

    hist_a = Session.get_history(pid, "chat_A")
    hist_b = Session.get_history(pid, "chat_B")

    assert length(hist_a) == 1
    assert length(hist_b) == 1
    assert hd(hist_a).id == d1.id
    assert hd(hist_b).id == d2.id
  end

  test "clear removes all history for a chat_id" do
    pid = start_session()
    Session.add_message(pid, "chat_1", sample_delta())
    Session.add_message(pid, "chat_1", sample_delta())
    assert length(Session.get_history(pid, "chat_1")) == 2

    :ok = Session.clear(pid, "chat_1")
    assert Session.get_history(pid, "chat_1") == []
  end

  test "clear does not affect other sessions" do
    pid = start_session()
    Session.add_message(pid, "chat_A", sample_delta())
    Session.add_message(pid, "chat_B", sample_delta())

    Session.clear(pid, "chat_A")

    assert Session.get_history(pid, "chat_A") == []
    assert length(Session.get_history(pid, "chat_B")) == 1
  end

  test "list_sessions returns all active chat_ids" do
    pid = start_session()
    assert Session.list_sessions(pid) == []

    Session.add_message(pid, "chat_1", sample_delta())
    Session.add_message(pid, "chat_2", sample_delta())

    sessions = Session.list_sessions(pid)
    assert "chat_1" in sessions
    assert "chat_2" in sessions
    assert length(sessions) == 2
  end

  test "list_sessions does not include cleared sessions" do
    pid = start_session()
    Session.add_message(pid, "chat_1", sample_delta())
    Session.add_message(pid, "chat_2", sample_delta())
    Session.clear(pid, "chat_1")

    sessions = Session.list_sessions(pid)
    refute "chat_1" in sessions
    assert "chat_2" in sessions
  end

  test "multiple concurrent sessions can be managed independently" do
    pid = start_session()

    chat_ids = for i <- 1..10, do: "chat_#{i}"

    # Add messages to all sessions
    Enum.each(chat_ids, fn cid ->
      for _ <- 1..3, do: Session.add_message(pid, cid, sample_delta())
    end)

    # Verify all have 3 messages
    Enum.each(chat_ids, fn cid ->
      assert length(Session.get_history(pid, cid)) == 3
    end)

    # Clear half
    {to_clear, to_keep} = Enum.split(chat_ids, 5)
    Enum.each(to_clear, &Session.clear(pid, &1))

    Enum.each(to_clear, fn cid ->
      assert Session.get_history(pid, cid) == []
    end)

    Enum.each(to_keep, fn cid ->
      assert length(Session.get_history(pid, cid)) == 3
    end)
  end

  test "get_history is readable directly without GenServer call" do
    # ETS read_concurrency: true means reads don't go through GenServer
    pid = start_session()
    d = sample_delta()
    Session.add_message(pid, "chat_x", d)

    # This should work because ETS is :public
    result = Session.get_history(pid, "chat_x")
    assert length(result) == 1
  end

  test "session stores any kind of delta" do
    pid = start_session()
    kinds = ["message.received", "llm.response", "llm.error", "plugin.loaded"]

    Enum.each(kinds, fn kind ->
      d = Delta.new(kind, %{"kind_test" => kind})
      Session.add_message(pid, "chat_multi", d)
    end)

    history = Session.get_history(pid, "chat_multi")
    assert length(history) == 4
    stored_kinds = Enum.map(history, & &1.kind)
    assert stored_kinds == kinds
  end

  # ── Rehydration tests ─────────────────────────────────────────────────────

  describe "rehydration from delta store" do
    test "session with no delta_store starts with empty history" do
      pid = start_session()
      assert Session.list_sessions(pid) == []
      assert Session.get_history(pid, "user_1") == []
    end

    test "session with empty store starts with empty history" do
      {pid, _store} = session_with_store([])
      assert Session.list_sessions(pid) == []
    end

    test "rehydrates message.received deltas as session.user messages" do
      d = human_delta("message.received", %{"text" => "Hello Kyber!"}, "user_42")
      {pid, _store} = session_with_store([d])

      history = Session.get_history(pid, "user_42")
      assert length(history) == 1

      [msg] = history
      assert msg.kind == "session.user"
      assert msg.payload["role"] == "user"
      assert msg.payload["content"] == "Hello Kyber!"
      # Original fields preserved
      assert msg.id == d.id
      assert msg.ts == d.ts
    end

    test "rehydrates llm.response deltas as session.assistant messages" do
      d = human_delta("llm.response", %{"content" => "Sure, I can help!"}, "user_99")
      {pid, _store} = session_with_store([d])

      history = Session.get_history(pid, "user_99")
      assert length(history) == 1

      [msg] = history
      assert msg.kind == "session.assistant"
      assert msg.payload["role"] == "assistant"
      assert msg.payload["content"] == "Sure, I can help!"
      assert msg.id == d.id
      assert msg.ts == d.ts
    end

    test "rehydrates channel-origin deltas using chat_id from origin" do
      d = channel_delta(
        "message.received",
        %{"text" => "Hello from Discord!"},
        "discord",
        "channel_123",
        "sender_456"
      )
      {pid, _store} = session_with_store([d])

      # chat_id should be the channel's chat_id, not the sender
      history = Session.get_history(pid, "channel_123")
      assert length(history) == 1
      assert hd(history).kind == "session.user"

      # No history under sender_id or channel name
      assert Session.get_history(pid, "sender_456") == []
      assert Session.get_history(pid, "discord") == []
    end

    test "rehydrates human-origin deltas using user_id as chat_id" do
      d = human_delta("message.received", %{"text" => "Hi!"}, "human_user_77")
      {pid, _store} = session_with_store([d])

      history = Session.get_history(pid, "human_user_77")
      assert length(history) == 1
    end

    test "ignores deltas with unknown origins" do
      d_cron = Delta.new("message.received", %{"text" => "cron msg"}, {:cron, "* * * * *"})
      d_system = system_delta("message.received", %{"text" => "system msg"})
      d_subagent = Delta.new("message.received", %{"text" => "sub msg"}, {:subagent, "parent_id"})
      d_tool = Delta.new("message.received", %{"text" => "tool msg"}, {:tool, "web_search"})

      {pid, _store} = session_with_store([d_cron, d_system, d_subagent, d_tool])

      # No sessions should be created for unknown origins
      assert Session.list_sessions(pid) == []
    end

    test "ignores non-rehydration delta kinds" do
      d1 = human_delta("llm.error", %{"error" => "timeout"}, "user_1")
      d2 = human_delta("plugin.loaded", %{"plugin" => "discord"}, "user_1")
      d3 = human_delta("cron.fired", %{"schedule" => "daily"}, "user_1")

      {pid, _store} = session_with_store([d1, d2, d3])

      # These kinds should not be rehydrated
      assert Session.get_history(pid, "user_1") == []
    end

    test "rehydration ordering: messages sorted by timestamp" do
      # Create deltas with controlled timestamps (note: Delta.new uses system time,
      # so we need small sleeps or we manually construct with ts values)
      base_ts = System.system_time(:millisecond)

      d1 = %Delta{
        Delta.new("message.received", %{"text" => "first"}, {:human, "user_order"})
        | ts: base_ts
      }
      d2 = %Delta{
        Delta.new("llm.response", %{"content" => "second"}, {:human, "user_order"})
        | ts: base_ts + 100
      }
      d3 = %Delta{
        Delta.new("message.received", %{"text" => "third"}, {:human, "user_order"})
        | ts: base_ts + 200
      }

      # Append out of order: d3, d1, d2
      {pid, _store} = session_with_store([d3, d1, d2])

      history = Session.get_history(pid, "user_order")
      assert length(history) == 3

      # Should be sorted by ts ascending
      timestamps = Enum.map(history, & &1.ts)
      assert timestamps == Enum.sort(timestamps)
      assert List.first(history).ts == base_ts
      assert List.last(history).ts == base_ts + 200
    end

    test "rehydration handles multiple independent chat sessions" do
      d_a1 = human_delta("message.received", %{"text" => "hello"}, "user_a")
      d_a2 = human_delta("llm.response", %{"content" => "hi there"}, "user_a")
      d_b1 = human_delta("message.received", %{"text" => "yo"}, "user_b")
      d_c1 = channel_delta("message.received", %{"text" => "sup"}, "discord", "chan_c", "s1")

      {pid, _store} = session_with_store([d_a1, d_a2, d_b1, d_c1])

      hist_a = Session.get_history(pid, "user_a")
      hist_b = Session.get_history(pid, "user_b")
      hist_c = Session.get_history(pid, "chan_c")

      assert length(hist_a) == 2
      assert length(hist_b) == 1
      assert length(hist_c) == 1

      sessions = Session.list_sessions(pid)
      assert "user_a" in sessions
      assert "user_b" in sessions
      assert "chan_c" in sessions
      assert length(sessions) == 3
    end

    test "rehydrated user message has correct role and content" do
      d = human_delta("message.received", %{"text" => "What is 2+2?"}, "user_math")
      {pid, _store} = session_with_store([d])

      [msg] = Session.get_history(pid, "user_math")
      assert msg.payload == %{"role" => "user", "content" => "What is 2+2?"}
    end

    test "rehydrated assistant message has correct role and content" do
      d = human_delta("llm.response", %{"content" => "The answer is 4."}, "user_math")
      {pid, _store} = session_with_store([d])

      [msg] = Session.get_history(pid, "user_math")
      assert msg.payload == %{"role" => "assistant", "content" => "The answer is 4."}
    end

    test "rehydrated message.received with missing text defaults to empty string" do
      d = human_delta("message.received", %{}, "user_empty")
      {pid, _store} = session_with_store([d])

      [msg] = Session.get_history(pid, "user_empty")
      assert msg.payload["content"] == ""
    end

    test "rehydrated llm.response with missing content defaults to empty string" do
      d = human_delta("llm.response", %{}, "user_empty2")
      {pid, _store} = session_with_store([d])

      [msg] = Session.get_history(pid, "user_empty2")
      assert msg.payload["content"] == ""
    end

    test "rehydration preserves original delta id" do
      d = human_delta("message.received", %{"text" => "hi"}, "user_id_check")
      {pid, _store} = session_with_store([d])

      [msg] = Session.get_history(pid, "user_id_check")
      assert msg.id == d.id
    end

    test "after rehydration, new messages can still be appended" do
      d_old = human_delta("message.received", %{"text" => "old message"}, "user_append")
      {pid, _store} = session_with_store([d_old])

      # Verify rehydrated
      assert length(Session.get_history(pid, "user_append")) == 1

      # Append a new live message
      d_new = sample_delta("message.received", "new live message")
      :ok = Session.add_message(pid, "user_append", d_new)

      history = Session.get_history(pid, "user_append")
      assert length(history) == 2
      # Rehydrated message first, then the live one
      assert hd(history).id == d_old.id
      assert List.last(history).id == d_new.id
    end

    test "after rehydration, clear works on rehydrated sessions" do
      d = human_delta("message.received", %{"text" => "hi"}, "user_clear")
      {pid, _store} = session_with_store([d])

      assert length(Session.get_history(pid, "user_clear")) == 1

      Session.clear(pid, "user_clear")
      assert Session.get_history(pid, "user_clear") == []
    end

    test "rehydration is non-destructive to existing ETS entries on session start" do
      # Both message.received and llm.response contribute to the same chat_id
      d1 = human_delta("message.received", %{"text" => "question"}, "user_convo")
      d2 = human_delta("llm.response", %{"content" => "answer"}, "user_convo")

      {pid, _store} = session_with_store([d1, d2])

      history = Session.get_history(pid, "user_convo")
      assert length(history) == 2
      kinds = Enum.map(history, & &1.kind)
      assert "session.user" in kinds
      assert "session.assistant" in kinds
    end

    test "rehydration handles a full conversation thread in order" do
      base_ts = System.system_time(:millisecond)
      origin = {:human, "user_thread"}

      msgs = [
        %Delta{Delta.new("message.received", %{"text" => "msg1"}, origin) | ts: base_ts},
        %Delta{Delta.new("llm.response", %{"content" => "resp1"}, origin) | ts: base_ts + 10},
        %Delta{Delta.new("message.received", %{"text" => "msg2"}, origin) | ts: base_ts + 20},
        %Delta{Delta.new("llm.response", %{"content" => "resp2"}, origin) | ts: base_ts + 30},
        %Delta{Delta.new("message.received", %{"text" => "msg3"}, origin) | ts: base_ts + 40},
      ]

      {pid, _store} = session_with_store(msgs)

      history = Session.get_history(pid, "user_thread")
      assert length(history) == 5

      expected_kinds = [
        "session.user", "session.assistant",
        "session.user", "session.assistant",
        "session.user"
      ]
      assert Enum.map(history, & &1.kind) == expected_kinds
    end

    test "rehydration does not fail if store has corrupt or unrelated deltas" do
      # This tests the graceful error handling path.
      # We put valid deltas alongside "other" kind ones — only the relevant ones are loaded.
      d_valid = human_delta("message.received", %{"text" => "safe"}, "user_mixed")
      d_noise = human_delta("tool.result", %{"data" => "noise"}, "user_mixed")
      d_llm = human_delta("llm.response", %{"content" => "response"}, "user_mixed")

      {pid, _store} = session_with_store([d_noise, d_valid, d_llm])

      history = Session.get_history(pid, "user_mixed")
      # Only message.received and llm.response should be rehydrated
      assert length(history) == 2
      assert Enum.all?(history, &(&1.kind in ["session.user", "session.assistant"]))
    end
  end
end
