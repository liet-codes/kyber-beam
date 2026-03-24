defmodule Kyber.SessionCleanupTest do
  use ExUnit.Case, async: true

  alias Kyber.{Session, Delta}

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp start_session(opts \\ []) do
    name = :"cleanup_session_#{:rand.uniform(999_999)}"
    {:ok, pid} = Session.start_link([name: name] ++ opts)
    pid
  end

  defp sample_delta(text \\ "hello") do
    Delta.new("message.received", %{"text" => text}, {:human, "user_1"})
  end

  # ── History cap tests ─────────────────────────────────────────────────────

  describe "history cap" do
    test "trims oldest messages when exceeding max_history" do
      pid = start_session(max_history: 5)

      # Add 8 messages
      deltas =
        for i <- 1..8 do
          d = sample_delta("msg_#{i}")
          Session.add_message(pid, "chat_cap", d)
          d
        end

      history = Session.get_history(pid, "chat_cap")

      # Should only keep the 5 most recent
      assert length(history) == 5

      # The kept messages should be the last 5 (msg_4 through msg_8)
      expected_ids = deltas |> Enum.slice(3, 5) |> Enum.map(& &1.id)
      actual_ids = Enum.map(history, & &1.id)
      assert actual_ids == expected_ids
    end

    test "does not trim when at or below max_history" do
      pid = start_session(max_history: 10)

      for i <- 1..10 do
        Session.add_message(pid, "chat_ok", sample_delta("msg_#{i}"))
      end

      history = Session.get_history(pid, "chat_ok")
      assert length(history) == 10
    end

    test "max_history defaults to 100" do
      pid = start_session()
      assert Session.max_history(pid) == 100
    end

    test "max_history is configurable" do
      pid = start_session(max_history: 25)
      assert Session.max_history(pid) == 25
    end

    test "cap applies per chat_id independently" do
      pid = start_session(max_history: 3)

      for i <- 1..5 do
        Session.add_message(pid, "chat_a", sample_delta("a_#{i}"))
        Session.add_message(pid, "chat_b", sample_delta("b_#{i}"))
      end

      assert length(Session.get_history(pid, "chat_a")) == 3
      assert length(Session.get_history(pid, "chat_b")) == 3
    end
  end

  # ── Stale session sweep tests ─────────────────────────────────────────────

  describe "sweep_stale" do
    test "removes sessions inactive longer than TTL" do
      pid = start_session()
      Session.add_message(pid, "stale_chat", sample_delta())

      # Small sleep to ensure the activity timestamp is in the past
      Process.sleep(10)

      # Sweep with a TTL of 1ms — everything older than 1ms is stale
      swept = Session.sweep_stale(pid, 1)

      assert "stale_chat" in swept
      assert Session.get_history(pid, "stale_chat") == []
      assert Session.list_sessions(pid) == []
    end

    test "active sessions survive sweep" do
      pid = start_session()
      Session.add_message(pid, "active_chat", sample_delta())

      # Sweep with a very long TTL — nothing should be swept
      swept = Session.sweep_stale(pid, :timer.hours(24))

      assert swept == []
      assert length(Session.get_history(pid, "active_chat")) == 1
    end

    test "only stale sessions are swept, active ones survive" do
      pid = start_session()

      # Add an "old" session
      Session.add_message(pid, "old_chat", sample_delta("old"))
      # Small sleep to create time gap
      Process.sleep(50)

      # Add a "fresh" session
      Session.add_message(pid, "fresh_chat", sample_delta("fresh"))

      # Sweep with TTL of 30ms — old_chat should be stale, fresh_chat should survive
      # (since we slept 50ms after old_chat but just wrote fresh_chat)
      swept = Session.sweep_stale(pid, 30)

      assert "old_chat" in swept
      refute "fresh_chat" in swept
      assert Session.get_history(pid, "old_chat") == []
      assert length(Session.get_history(pid, "fresh_chat")) == 1
    end

    test "sweep returns empty list when no sessions exist" do
      pid = start_session()
      assert Session.sweep_stale(pid, 0) == []
    end

    test "cleared sessions are not swept (already gone)" do
      pid = start_session()
      Session.add_message(pid, "cleared", sample_delta())
      Session.clear(pid, "cleared")

      swept = Session.sweep_stale(pid, 0)
      refute "cleared" in swept
    end
  end

  # ── Activity tracking tests ───────────────────────────────────────────────

  describe "activity tracking" do
    test "last_active returns timestamp after add_message" do
      pid = start_session()
      before = System.system_time(:millisecond)
      Session.add_message(pid, "tracked", sample_delta())
      after_ts = System.system_time(:millisecond)

      ts = Session.last_active(pid, "tracked")
      assert ts >= before
      assert ts <= after_ts
    end

    test "last_active returns nil for unknown chat_id" do
      pid = start_session()
      assert Session.last_active(pid, "unknown") == nil
    end

    test "last_active updates on subsequent writes" do
      pid = start_session()
      Session.add_message(pid, "chat_ts", sample_delta("first"))
      ts1 = Session.last_active(pid, "chat_ts")

      Process.sleep(5)

      Session.add_message(pid, "chat_ts", sample_delta("second"))
      ts2 = Session.last_active(pid, "chat_ts")

      assert ts2 > ts1
    end

    test "clear removes activity tracking" do
      pid = start_session()
      Session.add_message(pid, "will_clear", sample_delta())
      assert Session.last_active(pid, "will_clear") != nil

      Session.clear(pid, "will_clear")
      assert Session.last_active(pid, "will_clear") == nil
    end
  end

  # ── SessionCleaner GenServer tests ────────────────────────────────────────

  describe "SessionCleaner" do
    test "sweep_now triggers an immediate sweep" do
      session_name = :"cleaner_test_session_#{:rand.uniform(999_999)}"
      cleaner_name = :"cleaner_test_#{:rand.uniform(999_999)}"

      {:ok, session} = Session.start_link(name: session_name)
      Session.add_message(session, "chat_to_sweep", sample_delta())

      # Small sleep so the activity timestamp is in the past
      Process.sleep(10)

      {:ok, cleaner} =
        Kyber.SessionCleaner.start_link(
          name: cleaner_name,
          session: session_name,
          interval_ms: :timer.hours(1),  # long interval, won't auto-fire
          ttl_ms: 1  # 1ms TTL — everything older than 1ms is stale
        )

      swept = Kyber.SessionCleaner.sweep_now(cleaner)
      assert "chat_to_sweep" in swept
      assert Session.get_history(session, "chat_to_sweep") == []
    end

    test "periodic timer fires and sweeps" do
      session_name = :"periodic_session_#{:rand.uniform(999_999)}"
      cleaner_name = :"periodic_cleaner_#{:rand.uniform(999_999)}"

      {:ok, session} = Session.start_link(name: session_name)
      Session.add_message(session, "periodic_chat", sample_delta())

      # Small sleep so the activity timestamp is in the past
      Process.sleep(10)

      {:ok, _cleaner} =
        Kyber.SessionCleaner.start_link(
          name: cleaner_name,
          session: session_name,
          interval_ms: 50,  # fire quickly
          ttl_ms: 1  # 1ms TTL — everything older than 1ms is stale
        )

      # Wait for the periodic sweep to fire
      Process.sleep(100)

      assert Session.get_history(session, "periodic_chat") == []
    end
  end
end
