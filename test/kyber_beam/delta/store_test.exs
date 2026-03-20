defmodule Kyber.Delta.StoreTest do
  # Each test starts its own isolated store with a unique temp file — safe to run async.
  use ExUnit.Case, async: true

  alias Kyber.Delta
  alias Kyber.Delta.Store

  setup do
    # Use a unique temp file per test to avoid interference
    path = System.tmp_dir!() |> Path.join("kyber_test_#{:rand.uniform(999_999)}.jsonl")
    # Start a Task.Supervisor so broadcast can use supervised tasks
    {:ok, task_sup} = Task.Supervisor.start_link()
    on_exit(fn ->
      File.rm(path)
      try do
        if Process.alive?(task_sup), do: Supervisor.stop(task_sup, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)
    {:ok, pid} = Store.start_link(path: path, name: :"store_#{:rand.uniform(999_999)}", task_supervisor: task_sup)
    {:ok, store: pid, path: path, task_sup: task_sup}
  end

  test "appends a delta and returns :ok", %{store: store} do
    delta = Delta.new("message.received", %{"text" => "hello"})
    assert Store.append(store, delta) == :ok
  end

  test "query returns all appended deltas", %{store: store} do
    d1 = Delta.new("message.received", %{"n" => 1})
    d2 = Delta.new("error.route", %{"n" => 2})
    Store.append(store, d1)
    Store.append(store, d2)

    results = Store.query(store)
    assert length(results) == 2
    ids = Enum.map(results, & &1.id)
    assert d1.id in ids
    assert d2.id in ids
  end

  test "query filters by kind", %{store: store} do
    d1 = Delta.new("message.received", %{})
    d2 = Delta.new("error.route", %{})
    d3 = Delta.new("message.received", %{})
    Store.append(store, d1)
    Store.append(store, d2)
    Store.append(store, d3)

    results = Store.query(store, kind: "message.received")
    assert length(results) == 2
    assert Enum.all?(results, &(&1.kind == "message.received"))
  end

  test "query filters by since", %{store: store} do
    d1 = Delta.new("test.event", %{})
    Store.append(store, d1)
    Process.sleep(5)
    d2 = Delta.new("test.event", %{})
    Store.append(store, d2)

    # Use d1.ts + 1 as the cutoff — guaranteed to exclude d1, include d2
    results = Store.query(store, since: d1.ts + 1)
    assert length(results) == 1
    assert hd(results).id == d2.id
  end

  test "query respects limit", %{store: store} do
    for i <- 1..5 do
      Store.append(store, Delta.new("test.event", %{"i" => i}))
    end

    results = Store.query(store, limit: 3)
    assert length(results) == 3
  end

  test "subscribe receives new deltas", %{store: store} do
    test_pid = self()

    _unsubscribe = Store.subscribe(store, fn delta ->
      send(test_pid, {:got_delta, delta})
    end)

    delta = Delta.new("message.received", %{})
    Store.append(store, delta)

    assert_receive {:got_delta, received}, 500
    assert received.id == delta.id
  end

  test "unsubscribe stops delivery", %{store: store} do
    test_pid = self()

    unsubscribe = Store.subscribe(store, fn delta ->
      send(test_pid, {:got_delta, delta})
    end)

    # Confirm subscription works
    Store.append(store, Delta.new("test.event", %{}))
    assert_receive {:got_delta, _}, 500

    # Now unsubscribe
    unsubscribe.()
    Process.sleep(10)

    # This one should NOT be received
    Store.append(store, Delta.new("test.event", %{"after" => true}))
    refute_receive {:got_delta, _}, 200
  end

  test "multiple subscribers all receive events", %{store: store} do
    test_pid = self()

    _u1 = Store.subscribe(store, fn d -> send(test_pid, {:sub1, d.id}) end)
    _u2 = Store.subscribe(store, fn d -> send(test_pid, {:sub2, d.id}) end)

    delta = Delta.new("test.event", %{})
    Store.append(store, delta)

    assert_receive {:sub1, id}, 500
    assert_receive {:sub2, ^id}, 500
  end

  test "persists to disk and loads on restart", %{path: path, task_sup: task_sup} do
    store_name = :"reload_test_#{:rand.uniform(999_999)}"
    {:ok, s1} = Store.start_link(path: path, name: store_name, task_supervisor: task_sup)

    d1 = Delta.new("message.received", %{"persisted" => true})
    d2 = Delta.new("error.route", %{"persisted" => true})
    Store.append(s1, d1)
    Store.append(s1, d2)
    GenServer.stop(s1)

    # Start fresh — should reload from disk
    {:ok, s2} = Store.start_link(path: path, name: :"#{store_name}_2", task_supervisor: task_sup)
    results = Store.query(s2)
    assert length(results) == 2
    ids = Enum.map(results, & &1.id)
    assert d1.id in ids
    assert d2.id in ids
    GenServer.stop(s2)
  end

  test "query with combined filters", %{store: store} do
    for i <- 1..4 do
      Store.append(store, Delta.new("message.received", %{"i" => i}))
    end

    Store.append(store, Delta.new("error.route", %{}))

    results = Store.query(store, kind: "message.received", limit: 2)
    assert length(results) == 2
    assert Enum.all?(results, &(&1.kind == "message.received"))
  end

  # ── New tests for supervised broadcast and bounded memory ─────────────────

  test "crashing subscriber callback does not crash store or other subscribers",
       %{store: store} do
    test_pid = self()

    # Subscriber that always crashes
    _u1 = Store.subscribe(store, fn _delta -> raise "intentional crash" end)

    # Subscriber that is well-behaved
    _u2 = Store.subscribe(store, fn delta -> send(test_pid, {:healthy_sub, delta.id}) end)

    delta = Delta.new("test.event", %{})
    Store.append(store, delta)

    # The healthy subscriber must still receive the delta
    assert_receive {:healthy_sub, id}, 500
    assert id == delta.id

    # The store must still be alive after the crash
    assert Process.alive?(store)

    # Store must remain functional after a subscriber crash
    d2 = Delta.new("test.event", %{"after_crash" => true})
    assert Store.append(store, d2) == :ok
    assert_receive {:healthy_sub, _id2}, 500
  end

  test "max_memory_deltas trims oldest deltas from memory", %{path: path, task_sup: task_sup} do
    name = :"bounded_store_#{:rand.uniform(999_999)}"
    {:ok, store} = Store.start_link(path: path, name: name, task_supervisor: task_sup, max_memory_deltas: 5)
    on_exit(fn ->
      try do
        if Process.alive?(store), do: GenServer.stop(store, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    # Append 7 deltas — only the last 5 should remain in memory
    deltas = for i <- 1..7, do: Delta.new("test.event", %{"i" => i})
    Enum.each(deltas, &Store.append(store, &1))

    # Query without filters returns only in-memory deltas (last 5)
    results = Store.query(store)
    assert length(results) == 5

    # The first 2 deltas should have been dropped from memory
    first_two_ids = Enum.map(Enum.take(deltas, 2), & &1.id)
    result_ids = Enum.map(results, & &1.id)
    Enum.each(first_two_ids, fn id -> refute id in result_ids end)

    # But all 7 are on disk — verify via reload
    GenServer.stop(store)
    {:ok, s2} = Store.start_link(path: path, name: :"#{name}_2", task_supervisor: task_sup)
    all_results = Store.query(s2)
    assert length(all_results) == 7
    GenServer.stop(s2)
  end

  test "query falls back to disk when :since predates in-memory window",
       %{path: path, task_sup: task_sup} do
    name = :"fallback_store_#{:rand.uniform(999_999)}"
    {:ok, store} = Store.start_link(path: path, name: name, task_supervisor: task_sup, max_memory_deltas: 3)
    on_exit(fn ->
      try do
        if Process.alive?(store), do: GenServer.stop(store, :normal, 500)
      catch
        :exit, _ -> :ok
      end
    end)

    # Append 5 deltas — last 3 in memory, first 2 on disk only
    d_old = Delta.new("test.event", %{"old" => true})
    Store.append(store, d_old)
    Process.sleep(5)

    for i <- 1..4 do
      Store.append(store, Delta.new("test.event", %{"i" => i}))
    end

    # Query with since < oldest in-memory ts — should fall back to disk
    # and return d_old + newer deltas
    results = Store.query(store, since: d_old.ts)
    assert Enum.any?(results, &(&1.id == d_old.id)),
           "disk fallback should include old delta"
    assert length(results) == 5
  end

  test "broadcast uses task supervisor when provided", %{store: store, task_sup: task_sup} do
    # Verify task_sup is alive and broadcasts work end-to-end
    assert Process.alive?(task_sup)

    test_pid = self()
    _u = Store.subscribe(store, fn d -> send(test_pid, {:received, d.id}) end)

    delta = Delta.new("supervised.broadcast.test", %{})
    Store.append(store, delta)

    assert_receive {:received, id}, 500
    assert id == delta.id
  end
end
