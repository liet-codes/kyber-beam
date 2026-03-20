# Review: Memory Consolidator Refactor — Salience Layer over Knowledge Graph

**Reviewer:** Staff Engineer Review (automated)
**Date:** 2026-03-19
**Scope:** Knowledge subscription, Consolidator rewrite, ToolExecutor changes, tests

---

## Summary

The architectural direction is sound: separating salience (pool) from content (vault) from view (MEMORY.md) is a clean three-layer design that eliminates duplication. The vault_ref pointer model is the right call. However, the implementation has one critical blocking issue and several medium-severity gaps that need addressing before this is production-safe.

---

## HIGH Severity

### H1: `score_vault_notes` blocks the GenServer on synchronous HTTP calls

**File:** `consolidator.ex`, `handle_info({:vault_changed, paths}, state)` → `score_vault_notes/2`

**Problem:** When `{:vault_changed, paths}` arrives, `score_vault_notes/2` iterates over every changed path and calls `score_vault_note/4` synchronously — each making an HTTP request to Anthropic with a 30-second timeout. If Knowledge detects 10 changed files in one poll, the Consolidator GenServer is blocked for up to **10 × 30s = 5 minutes**. During this time:
- `consolidate_now/1` hangs
- `pin_memory/2`, `unpin_memory/2` hang
- `get_pool/1`, `list_memories/1` hang
- `reinforce/1` casts queue behind the blocking call
- The periodic `:consolidate` timer fires and queues behind it too

A vault `git pull` or Obsidian sync that touches 20+ files would effectively DoS the Consolidator.

**Fix:**
```elixir
def handle_info({:vault_changed, paths}, state) do
  # Fire-and-forget: score in a background Task, merge results via message
  server = self()
  auth_config = load_auth_config()
  knowledge = state.knowledge
  model = state.config.salience_model

  Task.start(fn ->
    results =
      paths
      |> Enum.map(fn path ->
        case score_single_note_async(path, auth_config, knowledge, model) do
          {:ok, vault_ref, salience, tags} -> {vault_ref, salience, tags}
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    send(server, {:scoring_complete, results})
  end)

  {:noreply, state}
end

def handle_info({:scoring_complete, results}, state) do
  Enum.each(results, fn {vault_ref, salience, tags} ->
    merge_vault_scored(vault_ref, salience, tags, state.table)
  end)
  {:noreply, state}
end
```

This mirrors how Knowledge already handles vault polling (async Task + send-back pattern).

**Additionally:** Add rate limiting. If Knowledge fires rapid vault_changed events (e.g., Obsidian writing 50 files on sync), debounce or batch them:

```elixir
def handle_info({:vault_changed, paths}, state) do
  pending = (state[:pending_score_paths] || []) ++ paths
  # Debounce: if we already have a pending timer, just accumulate paths
  state =
    if state[:score_timer] do
      %{state | pending_score_paths: Enum.uniq(pending)}
    else
      timer = Process.send_after(self(), :flush_score_batch, 2_000)
      %{state | pending_score_paths: Enum.uniq(pending), score_timer: timer}
    end
  {:noreply, state}
end
```

---

### H2: No subscription recovery when Knowledge starts after Consolidator (or restarts)

**File:** `consolidator.ex`, `init/1`

**Problem:** The subscription check is a one-shot in `init`:
```elixir
if Process.whereis(knowledge) do
  Kyber.Knowledge.subscribe(knowledge)
end
```

If `Kyber.Knowledge` starts after `Kyber.Memory.Consolidator` (supervision tree ordering), or if Knowledge crashes and restarts, the Consolidator silently loses vault change notifications **forever**. No scoring happens, pool goes stale.

**Fix:** Monitor Knowledge and re-subscribe on restart:
```elixir
# In init:
if pid = Process.whereis(knowledge) do
  Process.monitor(pid)
  Kyber.Knowledge.subscribe(knowledge)
end

# Add handle_info:
def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
  # Knowledge went down. Try to re-subscribe after a delay.
  Process.send_after(self(), :resubscribe_knowledge, 5_000)
  {:noreply, state}
end

def handle_info(:resubscribe_knowledge, state) do
  if pid = Process.whereis(state.knowledge) do
    Process.monitor(pid)
    Kyber.Knowledge.subscribe(state.knowledge)
    Logger.info("[Consolidator] re-subscribed to Knowledge")
  else
    # Retry in 5 seconds
    Process.send_after(self(), :resubscribe_knowledge, 5_000)
  end
  {:noreply, state}
end
```

---

## MEDIUM Severity

### M1: Silent data loss on JSONL migration (old `summary` entries dropped)

**File:** `consolidator.ex`, `map_to_memory/1`

**Problem:** The `with` clause requires `vault_ref` to be a binary:
```elixir
vault_ref when is_binary(vault_ref) <- Map.get(map, "vault_ref"),
```

Old pool entries with `"summary"` but no `"vault_ref"` fail this match and return `nil`, silently dropped by `load_pool`. The test "skips entries missing vault_ref" confirms this is intentional, but:
1. **No warning is logged.** Operator has no idea memories were dropped.
2. **No migration path.** Old entries are permanently lost on first load after upgrade.

**Fix:** Log dropped entries at warn level:
```elixir
defp map_to_memory(map) do
  with id when is_binary(id) <- Map.get(map, "id"),
       vault_ref when is_binary(vault_ref) <- Map.get(map, "vault_ref"),
       # ... rest
  else
    _ ->
      if Map.has_key?(map, "summary") do
        Logger.warning("[Consolidator] dropping legacy pool entry #{Map.get(map, "id", "?")} — has 'summary' but no 'vault_ref'. Run migration.")
      end
      nil
  end
end
```

Better yet: write a one-time migration task that converts old `summary` entries to vault notes and adds `vault_ref`.

---

### M2: ETS table is `:public` — bypasses GenServer serialization

**File:** `consolidator.ex`, `init/1`

**Problem:**
```elixir
:ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])
```

The table is `:public`, meaning any process can read AND write to it. The Consolidator relies on being the single writer (reinforcements buffered via cast, applied in consolidation cycle). But `merge_vault_scored/4` writes to ETS and is called from within `handle_info`, which is fine — unless the scoring is moved to a background Task (per H1 fix). In that case, the Task would write to ETS concurrently with the GenServer, creating race conditions.

**Fix:** Change to `:protected` (owner-write, anyone-read). If you move scoring to a Task, have the Task send results back to the GenServer for ETS insertion (as shown in H1 fix).

```elixir
:ets.new(table_name, [:named_table, :set, :protected, read_concurrency: true])
```

---

### M3: Dead subscriber cleanup only happens on vault changes

**File:** `knowledge.ex`, `handle_info({:reload_complete, ...}, state)`

**Problem:** Dead PIDs are pruned from `subscribers` only inside `reload_complete` when `changed_paths != []`. If the vault is stable for hours (no changes), dead PIDs accumulate in the list. While `Process.alive?/1` prevents crashes (dead PIDs just get a failed `send`), the list grows unbounded if subscribers churn.

This is unlikely to be a real issue (few subscribers, low churn), but for correctness:

**Fix:** Add periodic cleanup, or use `Process.monitor/1` at subscribe time:
```elixir
def handle_call({:subscribe, pid}, _from, state) do
  subs =
    if pid in state.subscribers do
      state.subscribers
    else
      Process.monitor(pid)  # Monitor for cleanup
      [pid | state.subscribers]
    end
  {:reply, :ok, %{state | subscribers: subs}}
end

def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
  {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}
end
```

---

### M4: Sensitive vault content sent to external API for scoring

**File:** `consolidator.ex`, `score_vault_note/4`

**Problem:** The scoring prompt sends up to 2,000 chars of L1 note content (frontmatter + first paragraph) to Anthropic Haiku:
```elixir
"Note content:\n#{String.slice(l1_content, 0, 2_000)}"
```

If a vault note's first paragraph contains API keys, passwords, personal information, or other secrets, they're sent to Anthropic. This is the same API provider used for conversations, so it's not a *new* third party, but:
1. The user might not expect vault notes to be automatically sent to LLM APIs
2. Content is sent via Haiku (smaller model) which may have different retention/logging policies
3. Identity/people notes could contain private info

**Fix:** Add a frontmatter opt-out mechanism and/or skip sensitive note types:
```elixir
# Skip sensitive note types from automatic scoring
@skip_scoring_types ["identity", "people"]

defp score_and_merge_vault_note(vault_ref, auth, state) do
  case safe_knowledge_get_tiered(state.knowledge, vault_ref, :l1) do
    {:ok, %{frontmatter: fm}} ->
      type = Map.get(fm, "type", "")
      no_score = Map.get(fm, "no_score", false)
      if type in @skip_scoring_types or no_score do
        Logger.debug("[Consolidator] skipping scoring for #{vault_ref} (type: #{type})")
      else
        # proceed with scoring...
      end
    _ -> nil
  end
end
```

---

### M5: MEMORY.md generation degrades to empty when Knowledge is down

**File:** `consolidator.ex`, `memory_line/2`, `write_memory_md/4`

**Problem:** If Knowledge is not running during a consolidation cycle, `memory_line/2` returns `nil` for every entry (because `safe_knowledge_get_tiered` catches the exit). Both persistent and drifting sections render as empty:
```
## Persistent (salience-ranked)
*No persistent memories yet.*

## Drifting (stochastic rotation)
*[populated by Memory.Consolidator — next rotation pending]*
```

This overwrites a previously-valid MEMORY.md with an empty one. Next time the agent loads MEMORY.md, it has no memories.

**Fix:** Skip MEMORY.md write when Knowledge is unavailable:
```elixir
defp write_memory_md(pool, path, config, knowledge) do
  # Don't overwrite MEMORY.md if Knowledge is down
  unless Process.whereis(knowledge) do
    Logger.warning("[Consolidator] Knowledge not running — skipping MEMORY.md regeneration")
    return
  end
  # ... rest of function
end
```

Or: keep a fallback that uses vault_ref paths as titles when L0 is unavailable.

---

## LOW Severity

### L1: `find_by_vault_ref` does linear scan of ETS

**File:** `consolidator.ex`, `find_by_vault_ref/2`

**Problem:** `find_by_vault_ref/2` calls `:ets.tab2list(table)` and iterates. Pool size is small now (likely <100 entries), but if it grows, this is O(n) on every vault change per changed file.

**Fix (deferred):** Add a secondary ETS table or `:ets.match` pattern. Not urgent at current scale.

---

### L2: No deduplication of vault_changed paths before scoring

**File:** `consolidator.ex`, `score_vault_notes/2`

**Problem:** If the same path appears multiple times in the `paths` list (unlikely but possible with rapid edits), it gets scored twice, wasting an API call.

**Fix:** `paths |> Enum.uniq() |> Enum.each(...)` — trivial one-liner.

---

### L3: Recency weight formula has a hard floor at 0.3

**File:** `consolidator.ex`, `compute_recency_weight/2`

```elixir
defp compute_recency_weight(created_at, now) do
  age_days = (now - created_at) / 86_400
  max(0.3, 1.0 - age_days / 30.0)
end
```

After 30 days, all memories have identical recency weight (0.3), so persistent ranking is purely by salience. This is probably fine but worth documenting as intentional. Very old but highly-salient memories dominate the persistent section permanently.

---

### L4: Test coverage gaps

**File:** `consolidator_test.exs`

**Missing tests:**
1. No integration test for the full consolidation cycle (`consolidate_now` with a running Knowledge mock)
2. No test for `reinforce/1` with a running Consolidator (only tests the no-op path)
3. No test for `memory_line/2` behavior when Knowledge returns `{:error, :not_found}` (dead ref rendering)
4. No test for the debounce/batching behavior recommended in H1
5. No test that MEMORY.md content is correct (only structural tests about pool ordering)

**File:** `knowledge_test.exs`

Subscription tests are solid — covers subscribe, unsubscribe, deletion notifications, no-change silence, and idempotent subscribe. Good coverage.

---

### L5: `put_note` doesn't notify subscribers

**File:** `knowledge.ex`, `handle_call({:put_note, ...})`

**Problem:** When a note is written via `put_note/4`, subscribers are NOT notified. Only `reload_complete` (from polling) fires notifications. This means if the Consolidator itself (or another process) writes a vault note via the Knowledge API, the change isn't scored until the next 5-second poll picks it up.

This is a minor latency gap, not a correctness issue. The poll will eventually detect the mtime change.

---

## Architecture Notes (non-blocking)

### Good decisions:
- **Three-layer separation** (salience / content / view) is clean and avoids the duplication trap
- **Event-driven scoring** is the right trigger model vs. periodic full-vault rescoring
- **Graceful fallbacks** — `safe_vault_ref_exists?` returns true when Knowledge is down, preventing false GC
- **Buffered reinforcements** — cast + apply-at-cycle-start avoids ETS races
- **Token budget enforcement** — recursive trimming of lowest-salience drifting entries is simple and correct

### Supervision tree concern:
Ensure `Kyber.Knowledge` is started **before** `Kyber.Memory.Consolidator` in the supervision tree. The current code handles the reverse (graceful skip in init), but then vault change scoring never activates unless H2's fix is applied.

---

## Priority Order for Fixes

1. **H1** — Async scoring (blocks GenServer, potential minutes of downtime)
2. **H2** — Subscription recovery (silent permanent failure mode)
3. **M5** — Don't overwrite MEMORY.md when Knowledge is down
4. **M2** — ETS to `:protected` (especially if H1 moves writes to Tasks)
5. **M4** — Sensitive content opt-out
6. **M1** — Migration logging for old entries
7. **M3** — Monitor-based subscriber cleanup
8. Rest are low-priority polish
