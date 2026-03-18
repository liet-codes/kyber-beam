defmodule Kyber.SessionTest do
  use ExUnit.Case, async: true

  alias Kyber.{Session, Delta}

  defp start_session do
    name = :"session_#{:rand.uniform(999_999)}"
    {:ok, pid} = Session.start_link(name: name)
    pid
  end

  defp sample_delta(kind \\ "message.received", text \\ "hello") do
    Delta.new(kind, %{"text" => text}, {:human, "user_1"})
  end

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
end
