defmodule Kyber.DistributionTest do
  use ExUnit.Case, async: false

  defp unique_name(prefix) do
    :"#{prefix}_#{:erlang.unique_integer([:positive])}"
  end

  setup do
    tmp_path = "test/tmp/dist_#{:erlang.unique_integer([:positive])}.jsonl"
    File.mkdir_p!("test/tmp")
    store_name = unique_name(:dist_store)

    {:ok, store} = Kyber.Delta.Store.start_link(path: tmp_path, name: store_name)
    # Unlink so the test process exiting with :shutdown doesn't kill the store
    Process.unlink(store)

    on_exit(fn ->
      if Process.alive?(store), do: GenServer.stop(store, :normal)
      File.rm(tmp_path)
    end)

    dist_name = unique_name(:kyber_dist)
    {:ok, dist} = Kyber.Distribution.start_link(store: store_name, name: dist_name)
    Process.unlink(dist)
    # Let handle_continue finish subscribing
    Process.sleep(50)

    on_exit(fn ->
      if Process.alive?(dist), do: GenServer.stop(dist, :normal)
    end)

    %{store: store, store_name: store_name, dist: dist, dist_name: dist_name}
  end

  describe "connect/2" do
    test "returns {:error, :unreachable} for non-existent node", %{dist: dist} do
      result = Kyber.Distribution.connect(dist, :"nonexistent@127.0.0.1")
      assert result == {:error, :unreachable}
    end

    test "does not add unreachable node to node list", %{dist: dist} do
      Kyber.Distribution.connect(dist, :"bad@127.0.0.1")
      assert Kyber.Distribution.nodes(dist) == []
    end
  end

  describe "disconnect/2" do
    test "returns :ok for nodes not in list", %{dist: dist} do
      assert :ok = Kyber.Distribution.disconnect(dist, :"some@node")
    end

    test "is idempotent — disconnect unknown node is a no-op", %{dist: dist} do
      assert :ok = Kyber.Distribution.disconnect(dist, :"fake@host")
      assert :ok = Kyber.Distribution.disconnect(dist, :"fake@host")
    end
  end

  describe "nodes/1" do
    test "returns empty list initially", %{dist: dist} do
      assert [] == Kyber.Distribution.nodes(dist)
    end
  end

  describe "receive_remote_delta" do
    test "accepts and stores a remote delta", %{dist: dist, store_name: store_name} do
      delta = Kyber.Delta.new("remote.event", %{"source_node" => "other@host"}, {:system, "test"})

      result = GenServer.call(dist, {:receive_remote_delta, delta})
      assert result == :ok

      stored = Kyber.Delta.Store.query(store_name)
      assert Enum.any?(stored, &(&1.id == delta.id))
    end

    test "deduplicates by delta ID", %{dist: dist} do
      delta = Kyber.Delta.new("dup.event", %{"source_node" => "other@host"})

      assert :ok = GenServer.call(dist, {:receive_remote_delta, delta})
      assert :duplicate = GenServer.call(dist, {:receive_remote_delta, delta})
    end

    test "dedup prevents loop-back — same delta stored exactly once", %{dist: dist, store_name: sn} do
      delta = Kyber.Delta.new("loop.test", %{"source_node" => "nodeA@host"})

      GenServer.call(dist, {:receive_remote_delta, delta})
      GenServer.call(dist, {:receive_remote_delta, delta})

      stored = Kyber.Delta.Store.query(sn)
      assert length(Enum.filter(stored, &(&1.id == delta.id))) == 1
    end
  end

  describe "broadcast_delta/2" do
    test "no-op when no nodes connected — does not crash", %{dist: dist} do
      delta = Kyber.Delta.new("local.event", %{})
      Kyber.Distribution.broadcast_delta(dist, delta)
      Process.sleep(50)
      assert Process.alive?(dist)
    end

    test "skips re-broadcasting remote-originated deltas", %{dist: dist} do
      delta = Kyber.Delta.new("foreign.event", %{"source_node" => "other@host"})
      Kyber.Distribution.broadcast_delta(dist, delta)
      Process.sleep(50)
      assert Process.alive?(dist)
    end
  end

  describe "nodeup / nodedown events" do
    test "handles :nodeup for unknown node without crashing", %{dist: dist} do
      send(dist, {:nodeup, :"unknown@host"})
      Process.sleep(50)
      assert Process.alive?(dist)
    end

    test "handles :nodedown and survives", %{dist: dist} do
      send(dist, {:nodedown, :"remote@host"})
      Process.sleep(50)
      assert Process.alive?(dist)
    end

    test "nodedown then nodeup cycles cleanly", %{dist: dist} do
      send(dist, {:nodedown, :"node_a@host"})
      send(dist, {:nodeup, :"node_a@host"})
      Process.sleep(100)
      assert Process.alive?(dist)
    end
  end

  describe "store subscription" do
    test "distribution stays alive after new delta appended to store", %{dist: dist, store_name: sn} do
      delta = Kyber.Delta.new("test.store_subscribe", %{})
      :ok = Kyber.Delta.Store.append(sn, delta)
      Process.sleep(100)
      assert Process.alive?(dist)
    end

    test "local delta broadcast path runs without crash", %{dist: dist, store_name: sn} do
      delta = Kyber.Delta.new("tag.test", %{})
      :ok = Kyber.Delta.Store.append(sn, delta)
      Process.sleep(100)
      assert Process.alive?(dist)
    end
  end
end
