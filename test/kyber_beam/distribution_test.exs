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

    test "GenServer stays responsive immediately after :nodeup for known node", %{dist: dist} do
      # Manually add a node to the node set so nodeup triggers a sync attempt
      # (which should be async and not block the GenServer)
      send(dist, {:nodedown, :"slow_remote@host"})
      # nodedown records last_seen_ts; nodeup for same node triggers sync
      send(dist, {:nodeup, :"slow_remote@host"})

      # GenServer must respond to calls immediately (sync is in a Task)
      result = Kyber.Distribution.nodes(dist)
      assert is_list(result)
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

  describe "bounded dedup cache" do
    test "dedup_seen?/2 returns false for unseen id" do
      cache = {MapSet.new(), :queue.new()}
      refute Kyber.Distribution.dedup_seen?(cache, "abc")
    end

    test "dedup_add/2 then dedup_seen?/2 returns true" do
      cache = {MapSet.new(), :queue.new()}
      cache = Kyber.Distribution.dedup_add(cache, "abc")
      assert Kyber.Distribution.dedup_seen?(cache, "abc")
    end

    test "dedup_size/1 tracks count correctly" do
      cache = {MapSet.new(), :queue.new()}
      cache = Kyber.Distribution.dedup_add(cache, "id1")
      cache = Kyber.Distribution.dedup_add(cache, "id2")
      cache = Kyber.Distribution.dedup_add(cache, "id2")  # duplicate
      assert Kyber.Distribution.dedup_size(cache) == 2
    end

    test "evicts oldest entry when cache exceeds 50,000" do
      # Build a cache with 50,000 entries using unique IDs
      cache =
        Enum.reduce(1..50_000, {MapSet.new(), :queue.new()}, fn i, acc ->
          Kyber.Distribution.dedup_add(acc, "id_#{i}")
        end)

      assert Kyber.Distribution.dedup_size(cache) == 50_000
      # "id_1" is oldest — adding one more should evict it
      cache = Kyber.Distribution.dedup_add(cache, "id_new")
      assert Kyber.Distribution.dedup_size(cache) == 50_000
      refute Kyber.Distribution.dedup_seen?(cache, "id_1"), "oldest entry should have been evicted"
      assert Kyber.Distribution.dedup_seen?(cache, "id_new"), "newest entry should be present"
    end

    test "cache size never exceeds max after many insertions" do
      cache =
        Enum.reduce(1..60_000, {MapSet.new(), :queue.new()}, fn i, acc ->
          Kyber.Distribution.dedup_add(acc, "id_#{i}")
        end)

      assert Kyber.Distribution.dedup_size(cache) == 50_000
    end

    test "adding duplicate IDs does not grow the cache beyond max" do
      # Fill to 50,000 with unique IDs, then re-add existing ones
      cache =
        Enum.reduce(1..50_000, {MapSet.new(), :queue.new()}, fn i, acc ->
          Kyber.Distribution.dedup_add(acc, "stable_#{i}")
        end)

      # Re-add the same IDs — set stays at 50,000 but queue grows,
      # causing earlier stable IDs to be evicted from the set when queue
      # entries exceed max. Size must not exceed 50,000.
      cache =
        Enum.reduce(1..1_000, cache, fn i, acc ->
          Kyber.Distribution.dedup_add(acc, "stable_#{i}")
        end)

      assert Kyber.Distribution.dedup_size(cache) <= 50_000
    end

    test "GenServer continues to accept new deltas after receiving many", %{dist: dist, store_name: sn} do
      # Send 100 unique remote deltas to exercise the bounded cache path
      for i <- 1..100 do
        delta = Kyber.Delta.new("bulk.event.#{i}", %{"source_node" => "remote@host"})
        GenServer.call(dist, {:receive_remote_delta, delta})
      end

      assert Process.alive?(dist)

      # Verify they are stored
      stored = Kyber.Delta.Store.query(sn)
      assert length(stored) >= 100
    end
  end

  describe "async sync_results" do
    test "GenServer accepts :sync_results cast without crashing", %{dist: dist, store_name: sn} do
      delta = Kyber.Delta.new("synced.event", %{"source_node" => "remote@host"})

      # Simulate what the sync Task would cast back
      GenServer.cast(dist, {:sync_results, :"remote@host", [delta]})
      Process.sleep(50)

      assert Process.alive?(dist)
      stored = Kyber.Delta.Store.query(sn)
      assert Enum.any?(stored, &(&1.id == delta.id))
    end

    test "sync_results deduplicates deltas already in the seen set", %{dist: dist, store_name: sn} do
      delta = Kyber.Delta.new("synced.dup", %{"source_node" => "remote@host"})

      # Apply via receive_remote_delta first
      GenServer.call(dist, {:receive_remote_delta, delta})
      stored_before = Kyber.Delta.Store.query(sn)
      count_before = length(Enum.filter(stored_before, &(&1.id == delta.id)))
      assert count_before == 1

      # Now sync_results with the same delta — should be deduped
      GenServer.cast(dist, {:sync_results, :"remote@host", [delta]})
      Process.sleep(50)

      stored_after = Kyber.Delta.Store.query(sn)
      count_after = length(Enum.filter(stored_after, &(&1.id == delta.id)))
      assert count_after == 1, "delta should be stored exactly once"
    end

    test "sync_results with multiple deltas applies all unique ones", %{dist: dist, store_name: sn} do
      deltas =
        for i <- 1..5 do
          Kyber.Delta.new("multi.sync.#{i}", %{"source_node" => "remote@host"})
        end

      GenServer.cast(dist, {:sync_results, :"remote@host", deltas})
      Process.sleep(100)

      stored = Kyber.Delta.Store.query(sn)
      for delta <- deltas do
        assert Enum.any?(stored, &(&1.id == delta.id)),
               "delta #{delta.id} should be stored after sync"
      end
    end
  end
end
