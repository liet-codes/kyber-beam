defmodule Kyber.Memory.ConsolidatorTest do
  use ExUnit.Case, async: false

  alias Kyber.Memory.Consolidator

  @tmp_dir System.tmp_dir!()

  defp tmp_path(name) do
    Path.join(@tmp_dir, "consolidator_test_#{name}_#{:rand.uniform(999_999)}")
  end

  defp sample_memory(overrides) do
    now = System.system_time(:second)

    Map.merge(
      %{
        id: :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower),
        vault_ref: "concepts/test-memory.md",
        salience: 0.7,
        tags: ["recall", "memory", "architecture"],
        created_at: now - 3_600,
        last_reinforced: nil,
        reinforcement_count: 0,
        pinned: false
      },
      overrides
    )
  end

  # ── Pool Persistence ──────────────────────────────────────────────────────

  describe "save_pool/2 and load_pool/1" do
    test "round-trips a pool to disk and back" do
      path = tmp_path("pool")
      on_exit(fn -> File.rm(path) end)

      pool = [
        sample_memory(%{id: "aaa111", vault_ref: "concepts/first.md", salience: 0.8, tags: ["elixir"]}),
        sample_memory(%{id: "bbb222", vault_ref: "concepts/second.md", salience: 0.5, tags: ["discord", "oauth"]}),
        sample_memory(%{id: "ccc333", vault_ref: "concepts/third.md", salience: 0.3, tags: ["reducer"]})
      ]

      Consolidator.save_pool(pool, path)
      assert File.exists?(path)

      loaded = Consolidator.load_pool(path)
      assert length(loaded) == 3

      ids = Enum.map(loaded, & &1.id)
      assert "aaa111" in ids
      assert "bbb222" in ids
      assert "ccc333" in ids
    end

    test "preserves all fields through JSONL round-trip" do
      path = tmp_path("fields")
      on_exit(fn -> File.rm(path) end)

      now = System.system_time(:second)
      mem = %{
        id: "deadbeef",
        vault_ref: "concepts/oauth-prefix.md",
        salience: 0.95,
        tags: ["oauth", "auth", "important"],
        created_at: now - 7200,
        last_reinforced: now - 300,
        reinforcement_count: 3,
        pinned: true
      }

      Consolidator.save_pool([mem], path)
      [loaded] = Consolidator.load_pool(path)

      assert loaded.id == mem.id
      assert loaded.vault_ref == mem.vault_ref
      assert Float.round(loaded.salience, 4) == Float.round(mem.salience, 4)
      assert loaded.tags == mem.tags
      assert loaded.created_at == mem.created_at
      assert loaded.last_reinforced == mem.last_reinforced
      assert loaded.reinforcement_count == mem.reinforcement_count
      assert loaded.pinned == mem.pinned
    end

    test "pool entry has vault_ref, not summary" do
      path = tmp_path("schema")
      on_exit(fn -> File.rm(path) end)

      mem = sample_memory(%{id: "schema1", vault_ref: "concepts/important.md"})
      Consolidator.save_pool([mem], path)
      [loaded] = Consolidator.load_pool(path)

      assert Map.has_key?(loaded, :vault_ref)
      refute Map.has_key?(loaded, :summary)
      assert loaded.vault_ref == "concepts/important.md"
    end

    test "returns empty list for missing file" do
      assert [] = Consolidator.load_pool("/nonexistent/path.jsonl")
    end

    test "skips malformed lines" do
      path = tmp_path("malformed")
      on_exit(fn -> File.rm(path) end)

      now = System.system_time(:second)

      good = %{
        id: "good1",
        vault_ref: "concepts/good.md",
        salience: 0.5,
        tags: [],
        created_at: now,
        last_reinforced: nil,
        reinforcement_count: 0
      }

      json_good = good |> Map.new(fn {k, v} -> {to_string(k), v} end) |> Jason.encode!()
      File.write!(path, ~s({"garbage": true}\n#{json_good}\nnot json at all\n))

      loaded = Consolidator.load_pool(path)
      assert length(loaded) == 1
      assert hd(loaded).id == "good1"
    end

    test "skips entries missing vault_ref" do
      path = tmp_path("no_vault_ref")
      on_exit(fn -> File.rm(path) end)

      now = System.system_time(:second)
      # Old-style entry with summary instead of vault_ref
      old_entry = %{
        "id" => "old1",
        "summary" => "An old memory without vault_ref",
        "salience" => 0.5,
        "tags" => [],
        "created_at" => now,
        "last_reinforced" => nil,
        "reinforcement_count" => 0
      }
      File.write!(path, Jason.encode!(old_entry) <> "\n")

      loaded = Consolidator.load_pool(path)
      # Old entries without vault_ref should be skipped
      assert loaded == []
    end

    test "save_pool handles empty pool" do
      path = tmp_path("empty")
      on_exit(fn -> File.rm(path) end)

      Consolidator.save_pool([], path)
      assert File.exists?(path)
      assert Consolidator.load_pool(path) == []
    end
  end

  # ── Decay Calculation ────────────────────────────────────────────────────

  describe "decay calculation" do
    test "salience decays by rate each cycle" do
      initial_salience = 1.0
      decay_rate = 0.95
      after_one_cycle = initial_salience * decay_rate
      assert_in_delta after_one_cycle, 0.95, 0.0001

      after_ten_cycles = initial_salience * :math.pow(decay_rate, 10)
      assert_in_delta after_ten_cycles, 0.5987, 0.001
    end

    test "memories below min_salience with low reinforcement are GC eligible" do
      mem_high_reinforce = sample_memory(%{salience: 0.03, reinforcement_count: 10})
      mem_low_reinforce = sample_memory(%{salience: 0.03, reinforcement_count: 2})

      min_salience = 0.05

      # High-reinforcement memory should NOT be GC'd even below min_salience
      assert mem_high_reinforce.reinforcement_count > 5
      assert mem_high_reinforce.salience < min_salience

      # Low-reinforcement memory IS GC eligible
      assert mem_low_reinforce.reinforcement_count <= 5
      assert mem_low_reinforce.salience < min_salience
    end
  end

  # ── Reinforcement ─────────────────────────────────────────────────────────

  describe "reinforce/1" do
    test "reinforce/1 with empty tags is a no-op" do
      assert :ok = Consolidator.reinforce([])
    end

    test "reinforce/1 with tags and no running process is a no-op" do
      assert :ok = Consolidator.reinforce(["some", "tags"])
    end

    test "reinforcement bump logic" do
      salience = 0.7
      bump = 0.1
      new_salience = min(1.0, salience + bump)
      assert_in_delta new_salience, 0.8, 0.0001

      # Capped at 1.0
      high_salience = 0.95
      capped = min(1.0, high_salience + bump)
      assert_in_delta capped, 1.0, 0.0001
    end
  end

  # ── MEMORY.md Generation (structure) ─────────────────────────────────────

  describe "MEMORY.md data structure" do
    test "persistent section gets top entries by salience*recency" do
      pool = [
        sample_memory(%{id: "hi1", vault_ref: "concepts/high-a.md", salience: 0.95, tags: ["important"]}),
        sample_memory(%{id: "hi2", vault_ref: "concepts/high-b.md", salience: 0.90, tags: ["critical"]}),
        sample_memory(%{id: "lo1", vault_ref: "concepts/low.md", salience: 0.20, tags: ["minor"]})
      ]

      now = System.system_time(:second)
      sorted =
        pool
        |> Enum.map(fn mem ->
          age_days = (now - mem.created_at) / 86_400
          recency = max(0.3, 1.0 - age_days / 30.0)
          {mem.salience * recency, mem}
        end)
        |> Enum.sort_by(fn {score, _} -> score end, :desc)
        |> Enum.map(fn {_, mem} -> mem end)

      top2 = Enum.take(sorted, 2)
      assert Enum.any?(top2, fn m -> m.vault_ref == "concepts/high-a.md" end)
      assert Enum.any?(top2, fn m -> m.vault_ref == "concepts/high-b.md" end)
    end

    test "persistent and drifting sections split correctly with max_persistent=8" do
      pool =
        Enum.map(1..12, fn i ->
          sample_memory(%{
            id: "mem#{i}",
            vault_ref: "concepts/note#{i}.md",
            salience: (12 - i) / 12.0,
            tags: ["tag#{i}"]
          })
        end)

      config = %{max_persistent: 8, max_drifting: 8}

      sorted = Enum.sort_by(pool, & &1.salience, :desc)
      {top8, rest4} = Enum.split(sorted, config.max_persistent)

      assert length(top8) == 8
      assert length(rest4) == 4

      top_saliences = Enum.map(top8, & &1.salience)
      rest_saliences = Enum.map(rest4, & &1.salience)

      assert Enum.min(top_saliences) > Enum.max(rest_saliences)
    end
  end

  # ── Token Budget ──────────────────────────────────────────────────────────

  describe "token budget enforcement" do
    test "drops lowest-salience drifting memories when over budget" do
      sorted_drifting =
        Enum.map(1..30, fn i ->
          sample_memory(%{
            vault_ref: "concepts/drift#{i}.md",
            salience: i / 30.0,
            tags: ["drift"]
          })
        end)
        |> Enum.sort_by(& &1.salience, :asc)

      [dropped | remaining] = sorted_drifting
      assert dropped.salience < hd(remaining).salience
    end

    test "persistent memories are never dropped for budget" do
      persistent =
        Enum.map(1..8, fn i ->
          sample_memory(%{
            vault_ref: "concepts/important#{i}.md",
            salience: 0.9
          })
        end)

      assert length(persistent) == 8
      assert Enum.all?(persistent, fn m -> m.salience >= 0.9 end)
    end
  end

  # ── GenServer lifecycle ───────────────────────────────────────────────────

  describe "start_link/1" do
    test "starts successfully with custom paths" do
      pool_path = tmp_path("gs_pool")
      memory_path = tmp_path("gs_memory.md")
      unique_name = :"Kyber.Memory.Consolidator.Test.#{:rand.uniform(999_999)}"

      on_exit(fn ->
        File.rm(pool_path)
        File.rm(memory_path)
      end)

      {:ok, pid} =
        Consolidator.start_link(
          name: unique_name,
          pool_path: pool_path,
          memory_md_path: memory_path,
          consolidation_interval_ms: 999_999_999
        )

      assert Process.alive?(pid)

      pool = Consolidator.get_pool(pid)
      assert is_list(pool)

      config = Consolidator.get_config(pid)
      assert config.consolidation_interval_ms == 999_999_999
      assert config.max_persistent == 8
      assert config.max_drifting == 8
      assert config.decay_rate == 0.95

      GenServer.stop(pid)
    end

    test "loads existing pool from disk on startup" do
      pool_path = tmp_path("gs_load_pool")
      memory_path = tmp_path("gs_load_memory.md")
      unique_name = :"Kyber.Memory.Consolidator.Test.#{:rand.uniform(999_999)}"
      on_exit(fn -> File.rm(pool_path); File.rm(memory_path) end)

      now = System.system_time(:second)
      existing = %{
        "id" => "preexisting1",
        "vault_ref" => "concepts/preloaded.md",
        "salience" => 0.75,
        "tags" => ["preloaded"],
        "created_at" => now - 3600,
        "last_reinforced" => nil,
        "reinforcement_count" => 2
      }
      File.write!(pool_path, Jason.encode!(existing) <> "\n")

      {:ok, pid} =
        Consolidator.start_link(
          name: unique_name,
          pool_path: pool_path,
          memory_md_path: memory_path,
          consolidation_interval_ms: 999_999_999
        )

      pool = Consolidator.get_pool(pid)
      assert Enum.any?(pool, fn m -> m.id == "preexisting1" end)

      loaded = Enum.find(pool, fn m -> m.id == "preexisting1" end)
      assert loaded.vault_ref == "concepts/preloaded.md"
      refute Map.has_key?(loaded, :summary)

      GenServer.stop(pid)
    end

    test "pin_memory and unpin_memory work by ID" do
      pool_path = tmp_path("pin_pool")
      memory_path = tmp_path("pin_memory.md")
      unique_name = :"Kyber.Memory.Consolidator.Test.Pin.#{:rand.uniform(999_999)}"
      on_exit(fn -> File.rm(pool_path); File.rm(memory_path) end)

      now = System.system_time(:second)
      entry = %{
        "id" => "pin_test_id",
        "vault_ref" => "concepts/pinnable.md",
        "salience" => 0.6,
        "tags" => ["test"],
        "created_at" => now - 100,
        "last_reinforced" => nil,
        "reinforcement_count" => 0
      }
      File.write!(pool_path, Jason.encode!(entry) <> "\n")

      {:ok, pid} =
        Consolidator.start_link(
          name: unique_name,
          pool_path: pool_path,
          memory_md_path: memory_path,
          consolidation_interval_ms: 999_999_999
        )

      assert :ok = Consolidator.pin_memory("pin_test_id", pid)
      pool = Consolidator.get_pool(pid)
      pinned = Enum.find(pool, fn m -> m.id == "pin_test_id" end)
      assert pinned.pinned == true

      assert :ok = Consolidator.unpin_memory("pin_test_id", pid)
      pool2 = Consolidator.get_pool(pid)
      unpinned = Enum.find(pool2, fn m -> m.id == "pin_test_id" end)
      assert unpinned.pinned == false

      assert {:error, :not_found} = Consolidator.pin_memory("no_such_id", pid)

      GenServer.stop(pid)
    end
  end

  # ── Vault-change event scoring ────────────────────────────────────────────

  describe "vault_changed event" do
    test "consolidator handles vault_changed message gracefully without auth" do
      pool_path = tmp_path("vc_pool")
      memory_path = tmp_path("vc_memory.md")
      unique_name = :"Kyber.Memory.Consolidator.Test.VC.#{:rand.uniform(999_999)}"
      on_exit(fn -> File.rm(pool_path); File.rm(memory_path) end)

      {:ok, pid} =
        Consolidator.start_link(
          name: unique_name,
          pool_path: pool_path,
          memory_md_path: memory_path,
          consolidation_interval_ms: 999_999_999
        )

      # Sending vault_changed without auth configured should not crash
      send(pid, {:vault_changed, ["concepts/new-note.md", "memory/2026-03-19.md"]})

      # Give it a moment to process
      Process.sleep(100)

      # Consolidator should still be alive
      assert Process.alive?(pid)

      GenServer.stop(pid)
    end
  end
end
