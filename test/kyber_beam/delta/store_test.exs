defmodule Kyber.Delta.StoreTest do
  use ExUnit.Case, async: false

  alias Kyber.Delta
  alias Kyber.Delta.Store

  setup do
    # Use a unique temp file per test to avoid interference
    path = System.tmp_dir!() |> Path.join("kyber_test_#{:rand.uniform(999_999)}.jsonl")
    on_exit(fn -> File.rm(path) end)
    {:ok, pid} = Store.start_link(path: path, name: :"store_#{:rand.uniform(999_999)}")
    {:ok, store: pid, path: path}
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

  test "persists to disk and loads on restart", %{path: path} do
    store_name = :"reload_test_#{:rand.uniform(999_999)}"
    {:ok, s1} = Store.start_link(path: path, name: store_name)

    d1 = Delta.new("message.received", %{"persisted" => true})
    d2 = Delta.new("error.route", %{"persisted" => true})
    Store.append(s1, d1)
    Store.append(s1, d2)
    GenServer.stop(s1)

    # Start fresh — should reload from disk
    {:ok, s2} = Store.start_link(path: path, name: :"#{store_name}_2")
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
end
