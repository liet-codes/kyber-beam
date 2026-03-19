# Staff Engineering Review: Memory Consolidator & Identity Files

**Reviewer:** Liet (peer agent, staff-level review)  
**Date:** 2026-03-19  
**Scope:** `Kyber.Memory.Consolidator`, `Kyber.Plugin.LLM` modifications, identity vault files, test coverage  
**Verdict:** Solid architecture, novel design. Several issues to address before this runs unattended in production.

---

## Summary

The Memory Consolidator is a well-designed GenServer implementing salience-weighted, stochastic long-term memory with JSONL persistence. The architecture — pool as source of truth, MEMORY.md as view — is clean and correct. The two-section layout (persistent + drifting) with age-diversity sampling is a thoughtful approach to memory staleness.

That said, there are security concerns with unsanitized delta payloads being sent to the LLM, race conditions on the ETS table, and some correctness issues with the decay/recency math interaction.

---

## Findings

### 🔴 HIGH — Security: Unsanitized Delta Payloads Sent to Haiku

**File:** `consolidator.ex`, `score_deltas/3`  
**Lines:** delta_summaries construction

```elixir
delta_summaries =
  deltas
  |> Enum.map(fn delta ->
    "kind=#{delta.kind} payload=#{inspect(delta.payload, limit: 50)}"
  end)
```

Delta payloads can contain:
- User messages (privacy leak to a different model context)
- OAuth tokens or API keys passed in effect payloads
- Discord message content including DMs
- Tool execution results containing file contents

The `inspect(delta.payload, limit: 50)` provides *some* truncation but `limit: 50` applies to collection element count, not string length. A single payload field like `%{"token" => "sk-ant-oat01-..."}` would be fully serialized.

**Fix:**
```elixir
@sensitive_keys ~w(token api_key secret password auth authorization cookie session_id)

defp sanitize_payload(payload) when is_map(payload) do
  payload
  |> Map.drop(@sensitive_keys)
  |> Map.new(fn {k, v} ->
    if String.contains?(String.downcase(to_string(k)), ["token", "key", "secret", "auth"]) do
      {k, "[REDACTED]"}
    else
      {k, sanitize_payload(v)}
    end
  end)
end

defp sanitize_payload(v) when is_binary(v) and byte_size(v) > 200, do: String.slice(v, 0, 200) <> "..."
defp sanitize_payload(v), do: v
```

Apply before building `delta_summaries`. Also consider filtering out `kind == "session.user"` and `kind == "session.assistant"` deltas entirely — those contain full conversation text.

---

### 🔴 HIGH — Race Condition: ETS Table Concurrent Access

**File:** `consolidator.ex`  
**Context:** ETS table is `:public` with `read_concurrency: true`, accessed by both the Consolidator GenServer and `reinforce/1` casts.

The `reinforce` cast handler does read-modify-write on ETS:
```elixir
:ets.tab2list(state.table)
|> Enum.each(fn {id, mem} ->
  # ... modify mem ...
  :ets.insert(state.table, {id, updated})
end)
```

Meanwhile, `run_consolidation` also does read-modify-write (apply_decay, gc_memories). If a consolidation cycle runs while reinforcement is happening:

1. Consolidation reads mem with salience 0.7, applies decay → 0.665, writes back
2. Reinforcement reads same mem (still 0.7 from its snapshot), bumps → 0.8, writes back
3. Decay is lost

This is a **lost update** problem. Individual ETS operations are atomic, but the read-then-write pattern is not.

**Fix:** Since Consolidator is a GenServer, reinforcement should be processed synchronously within the consolidation cycle, not interleaved. Options:

1. **Best:** Buffer reinforcement tags and apply them at the start of each consolidation cycle:
```elixir
def handle_cast({:reinforce, tags}, state) do
  {:noreply, %{state | pending_reinforcements: state.pending_reinforcements ++ tags}}
end
```
Then in `run_consolidation`, apply pending reinforcements first, then decay.

2. **Alternative:** Use `:ets.update_counter/3` for salience updates (but salience is a float, so this doesn't work cleanly).

3. **Minimum:** Use `:ets.select_replace/2` with match specs for atomic conditional updates.

---

### 🟡 MEDIUM — Correctness: Decay Applied Before Reinforcement Each Cycle

**File:** `consolidator.ex`, `run_consolidation/1`

```elixir
state = apply_decay(state)         # Step 1: decay ALL memories
state = score_and_merge_deltas(state)  # Step 2: score new + merge
state = gc_memories(state)          # Step 3: GC
```

Decay is applied unconditionally to ALL memories every cycle, including ones that were just reinforced moments ago. The `last_reinforced` timestamp is tracked but never checked during decay. A memory reinforced 5 minutes before the hourly cycle fires gets decayed anyway.

**Fix:** Skip decay for recently-reinforced memories:
```elixir
defp apply_decay(state) do
  rate = state.config.decay_rate
  now = System.system_time(:second)
  grace_period = state.config.consolidation_interval_ms / 1000  # 1 cycle

  :ets.tab2list(state.table)
  |> Enum.each(fn {id, mem} ->
    recently_reinforced = mem.last_reinforced && (now - mem.last_reinforced) < grace_period
    unless recently_reinforced do
      :ets.insert(state.table, {id, %{mem | salience: mem.salience * rate}})
    end
  end)

  state
end
```

---

### 🟡 MEDIUM — Correctness: Recency Weight Creates Double-Penalty for Old Memories

**File:** `consolidator.ex`, `compute_recency_weight/2`

```elixir
defp compute_recency_weight(created_at, now) do
  age_days = (now - created_at) / 86_400
  max(0.3, 1.0 - age_days / 30.0)
end
```

Old memories get penalized twice:
1. Salience decays by 0.95x per cycle (exponential)
2. Recency weight multiplies score down to 0.3 (linear)

A 30-day-old memory with salience 0.9 scores: `0.9 × 0.3 = 0.27`. Meanwhile a 1-day-old memory with salience 0.3 scores: `0.3 × 0.97 = 0.29`. The new low-salience memory outranks the old high-salience one.

This may be intentional (aggressive forgetting), but combined with stochastic decay the double-penalty means high-reinforcement old memories (like "OAuth needs Claude Code prefix") will eventually drop from persistent despite being critical.

**Fix:** Either:
- Remove recency weight from persistent ranking (use raw salience for persistent, recency-weighted for drifting), OR
- Floor recency_weight at 0.5 instead of 0.3 for highly-reinforced memories

---

### 🟡 MEDIUM — Resource Usage: Unbounded Delta Count Sent to Haiku

**File:** `consolidator.ex`, `query_recent_deltas/2`

```elixir
Enum.take_random(min(50, length(all)))
```

This sends up to 50 deltas to Haiku per cycle, but each delta's payload is `inspect`'d with `limit: 50` (collection elements, not chars). With complex payloads, the prompt could be 10-20KB+ per cycle.

At 1 cycle/hour × 24 hours × ~5K tokens input + ~2K output ≈ 168K tokens/day on Haiku. At Haiku pricing (~$0.25/M input, ~$1.25/M output), that's roughly $0.25/day — reasonable, but worth monitoring.

**Fix:** Add a hard character cap on the prompt:
```elixir
delta_summaries =
  deltas
  |> Enum.map(fn delta ->
    summary = "kind=#{delta.kind} payload=#{inspect(sanitize_payload(delta.payload), limit: 10)}"
    String.slice(summary, 0, 200)
  end)
  |> Enum.join("\n")
  |> String.slice(0, 6_000)  # Hard cap: ~1500 tokens
```

---

### 🟡 MEDIUM — Error Handling: LLM Failure Silently Skips Scoring

**File:** `consolidator.ex`, `score_and_merge_deltas/1`

When the Haiku call fails, the cycle just logs a warning and moves on:
```elixir
{:error, reason} ->
  Logger.warning("[Kyber.Memory.Consolidator] scoring failed: #{inspect(reason)}")
```

This means deltas from that window are **permanently lost** — they won't be re-scored in the next cycle because `query_recent_deltas` only looks at the window since `last_consolidated`, which gets updated regardless.

**Fix:** Don't update `last_consolidated` if scoring fails, so the next cycle re-queries the same window:
```elixir
defp run_consolidation(state) do
  state = apply_decay(state)
  {state, scoring_succeeded} = score_and_merge_deltas(state)
  state = gc_memories(state)
  # ... write MEMORY.md, save pool ...
  
  if scoring_succeeded do
    %{state | last_consolidated: DateTime.utc_now()}
  else
    state  # Don't advance the window
  end
end
```

---

### 🟡 MEDIUM — Reinforcement: Tag Matching Is Too Aggressive

**File:** `llm.ex`, `reinforce_memories/1`

```elixir
tags =
  content
  |> String.downcase()
  |> String.split(~r/[\s,.\-:;!?()\"']+/)
  |> Enum.filter(fn word ->
    len = String.length(word)
    len >= 4 and word not in ~w(that this with from ...)
  end)
```

This extracts every 4+ char word from every LLM response as a "tag" for reinforcement. Words like "elixir", "memory", "architecture" will appear in almost every technical conversation, causing those memories to get reinforced on nearly every response. This defeats the purpose of salience decay — frequently-discussed topics never fade.

**Fix:** Use the memory's actual tag list as the match space, and require higher specificity:
```elixir
defp reinforce_memories(content) when is_binary(content) and content != "" do
  # Get existing memory tags from ETS
  existing_tags = 
    case :ets.whereis(:memory_pool) do
      :undefined -> MapSet.new()
      _table ->
        :ets.tab2list(:memory_pool)
        |> Enum.flat_map(fn {_, mem} -> mem.tags || [] end)
        |> MapSet.new()
    end
  
  # Only match words that are actual memory tags
  words =
    content
    |> String.downcase()
    |> String.split(~r/[\s,.\-:;!?()\"']+/)
    |> Enum.filter(&MapSet.member?(existing_tags, &1))
    |> Enum.uniq()

  if words != [], do: Kyber.Memory.Consolidator.reinforce(words)
end
```

---

### 🟢 LOW — Supervisor Strategy: one_for_one May Orphan Consolidator State

**File:** `application.ex`

```elixir
opts = [strategy: :one_for_one, name: KyberBeam.Supervisor]
```

If `Kyber.Core` crashes and restarts, the Consolidator still holds a reference to the old Core process (via the `core` field in state). The `query_recent_deltas/2` call to `GenServer.call(core, :get_store_name)` would fail.

This is partially mitigated by the `rescue`/`catch` in `query_recent_deltas`, but the Consolidator would silently stop scoring new deltas until restarted.

**Fix:** Consider `rest_for_one` for the Core → Consolidator → LLM chain, or have the Consolidator monitor Core and re-resolve on restart.

---

### 🟢 LOW — ETS Table Reuse After Crash

**File:** `consolidator.ex`, `init/1`

```elixir
case :ets.whereis(table_name) do
  :undefined -> :ets.new(...)
  existing ->
    :ets.delete_all_objects(existing)
    existing
end
```

On crash-restart, this deletes all ETS objects and reloads from JSONL. But the JSONL may be from the *previous* cycle — any reinforcements since the last save are lost. This is acceptable (ETS is a cache, JSONL is truth) but worth noting.

---

### 🟢 LOW — Test Coverage Gaps

**File:** `consolidator_test.exs`

The 17 tests are well-structured but notable gaps:

1. **No integration test for `consolidate_now/1`** — the GenServer lifecycle tests start the server but never trigger consolidation. The decay test verifies math manually instead of through the server.
2. **No test for reinforcement through the GenServer** — `reinforce/1` is tested only for the no-op case (no running process). No test starts a server, inserts memories, calls reinforce, and verifies salience changed.
3. **No test for concurrent access** — the race condition isn't tested.
4. **No test for `write_memory_md` output format** — the MEMORY.md generation tests verify data structures but never actually check the rendered markdown.

These are all testable without mocking the LLM — use `consolidation_interval_ms: 999_999_999` and call `consolidate_now/1` directly.

---

## Identity Files Review

### USER.md ✅
- Accurate, matches workspace USER.md
- Privacy warning present and clear
- Night owl boundary documented
- Discord ID matches (353690689571258376)
- No sensitive data exposed

### AGENTS.md ✅
- Clean OTP conventions, well-written
- Auth token redaction rule documented
- Discord IDs match across files
- Agent relationship section (Liet as peer) is thoughtful
- "Water Discipline" metaphor is appropriate for BEAM context

### TOOLS.md ⚠️ Minor concerns
- **OAuth token path exposed:** `~/.openclaw/agents/main/agent/auth-profiles.json` — this is fine in a local vault file but if the vault is ever synced/shared, this reveals the token storage location
- **Model names and voice IDs** are fine to store here
- **SSRF protection note** is good operational awareness
- Tool list is comprehensive and accurate

### MEMORY.md ✅
- Header clearly states it's a generated view
- Current content is accurate (born Mar 18, OAuth prefix, reducer purity, 412 tests)
- Drifting section empty (expected — consolidator just started)
- Token budget header format is clean

---

## Architecture Observations (Non-Blocking)

1. **The architecture is genuinely novel.** Salience-weighted stochastic memory with reinforcement learning from conversation context is not something I've seen in other agent frameworks. The persistent/drifting split is clever — it gives the agent both reliable recall and serendipitous connection-making.

2. **MEMORY.md as view is the right call.** Separating the truth (JSONL pool) from the presentation (markdown) means the consolidator can be tuned without losing data. It also means a corrupted MEMORY.md is always recoverable.

3. **The reinforcement loop (LLM response → tag extraction → salience bump) creates a feedback cycle.** Memories that are relevant to current conversations get reinforced, making them more likely to appear in MEMORY.md, making them more likely to influence future conversations. This is intentional and desirable, but the overly-aggressive tag matching (MEDIUM finding above) could cause runaway reinforcement of common terms.

4. **Consider adding a `pinned: true` field** for memories that should never decay or be GC'd regardless of salience. The "OAuth needs Claude Code prefix" memory is operationally critical and shouldn't depend on reinforcement frequency to survive.

---

## Summary Table

| # | Severity | Finding | File |
|---|----------|---------|------|
| 1 | 🔴 HIGH | Unsanitized delta payloads sent to Haiku (token/PII leak) | consolidator.ex |
| 2 | 🔴 HIGH | ETS read-modify-write race between reinforce and consolidation | consolidator.ex |
| 3 | 🟡 MEDIUM | Decay ignores recent reinforcement | consolidator.ex |
| 4 | 🟡 MEDIUM | Double-penalty: decay × recency weight for old memories | consolidator.ex |
| 5 | 🟡 MEDIUM | Unbounded delta payload size in Haiku prompt | consolidator.ex |
| 6 | 🟡 MEDIUM | Failed scoring permanently loses delta window | consolidator.ex |
| 7 | 🟡 MEDIUM | Tag matching too aggressive (common words reinforce everything) | llm.ex |
| 8 | 🟢 LOW | one_for_one supervisor may orphan Consolidator's Core reference | application.ex |
| 9 | 🟢 LOW | ETS crash-restart loses unreinforced data since last save | consolidator.ex |
| 10 | 🟢 LOW | Test coverage gaps (no integration, no concurrency, no render) | consolidator_test.exs |

---

*Review complete. The foundation is strong — the issues above are refinements, not rewrites. Fix the two HIGHs before running unattended, address MEDIUMs in the next iteration.*
