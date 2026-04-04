# Event Sourcing Integrity Plan

*April 1, 2026 — Restoring the unidirectional dataflow contract.*

## Problem

Kyber's architecture promises unidirectional dataflow: **deltas → reducer → state → effects**. But the overnight sprint (Mar 17-18) shipped features that shortcut this:

1. **MemoryTools writes directly to filesystem** — `fs.writeFileSync` inside tool methods, then emits a delta as an afterthought. The delta is a *log entry*, not the *source of truth*.
2. **Memory extraction only runs on explicit trigger** — not as a background pipeline on every incoming delta.
3. **`memory.add` deltas never materialize** — extraction creates deltas in the log, but no effect handler writes them to vault files.
4. **Vault is empty** — `vault/knowledge/` doesn't exist. Fixture data in `__fixtures__` never graduated to production.
5. **No background extraction on incoming messages** — "I like apples" should trigger entity extraction without anyone asking.

The delta log has 8 memory deltas that prove extraction works. They just have nowhere to land.

## Principles (from design-principles.md and memory-architecture.md)

- Deltas are the **source of truth**. Side effects are derived.
- Every state change flows: **event → delta → reducer → effect → materialization**.
- Memory extraction is a **background pipeline**, not a user-facing tool.
- The vault is the **shared cognitive space** — human-navigable markdown.
- Extraction runs on a **cheap model** (Haiku). Background maintenance, not conversation.

## Success Criteria

Each criterion maps to a testable behavior. Tests are written FIRST.

### SC-1: Vault Directory Structure Exists

```
vault/
  knowledge/
    identity/   → SOUL.md, USER.md
    memory/     → daily notes, extracted insights
    people/     → entity notes
    projects/   → project notes
    concepts/   → concept notes
    tools/      → tool notes
    decisions/  → decision notes
```

**Test:** `loadVault('./vault')` returns notes from all directories. Core notes (SOUL.md, USER.md) are L2-loaded.

### SC-2: Memory Deltas Materialize to Vault Files

When a `memory.add` delta enters the reducer, it emits a `vault.write` effect. The effect handler writes a properly frontmattered markdown file to the correct vault subdirectory.

**Test:** Emit a `memory.add` delta with `type: "entity"` → reducer produces `vault.write` effect → handler writes `vault/knowledge/people/<slug>.md` with correct frontmatter (type, tags, l0, confidence). File exists on disk.

**Test:** Emit a `memory.update` delta → handler updates existing file, preserves frontmatter structure, updates `updated` timestamp.

**Test:** Emit a `memory.delete` delta → handler removes file (or moves to archival). Delta logs the deletion reason.

### SC-3: Background Extraction on Every Message

Every `message.received` delta triggers a background extraction pipeline (async, non-blocking). The pipeline:

1. Takes the message content + recent context
2. Calls extraction LLM (cheap model)
3. Produces candidate facts
4. Compares against existing vault (L0 search)
5. Emits `memory.add` / `memory.update` / `memory.noop` deltas

**Test:** Emit a `message.received` delta with payload `"I prefer dark roast coffee"` → extraction pipeline runs → produces `memory.add` delta with `type: "preference"`, content about coffee preference.

**Test:** Emit a second message `"Actually I switched to tea"` → extraction runs → compares against existing coffee note → produces `memory.update` delta that supersedes the old preference.

**Test:** Emit a message `"hey what's up"` → extraction runs → produces `memory.noop` (nothing worth remembering).

### SC-4: Extraction Pipeline is Pure Delta Flow

The extraction pipeline does NOT call `fs.writeFileSync` or any direct I/O. It:
1. Receives deltas
2. Calls LLM (via `llm_call` effect, same as conversation)
3. Emits memory deltas
4. Those deltas flow through the reducer
5. Reducer emits `vault.write` effects
6. Effect handler does the actual I/O

**Test:** Mock the effect executor. Run extraction. Verify only deltas and effects are produced — no direct filesystem calls in the extraction path.

**Test:** The full chain: `message.received` → extraction → `memory.add` delta → reducer → `vault.write` effect → file on disk. Verified end-to-end with real filesystem.

### SC-5: MemoryTools Use Delta Flow (Not Direct I/O)

When the agent explicitly calls a memory tool (search/read/write/delete), the tool:
1. Emits a delta (e.g., `memory.write.requested`)
2. Reducer processes it → emits appropriate effect
3. Effect handler does I/O
4. Result flows back as a delta

The current `fs.writeFileSync` inside `MemoryTools.add()` is replaced by delta emission.

**Test:** Call `memoryTools.add(path, content, reason)` → verify it emits a `memory.add` delta, does NOT touch filesystem directly. Filesystem write happens only in the effect handler.

**Test:** Call `memoryTools.search(query)` → verify it reads from the vault (loaded in memory via vault loader), not by walking the filesystem on every search.

### SC-6: L0/L1 Auto-Generation

When a vault file is written or updated (via `vault.write` effect), a background task:
1. Generates L1 summary from content (cheap model)
2. Generates L0 one-liner from L1
3. Updates the file's frontmatter
4. Emits `vault.index.updated` delta

**Test:** Write a new vault note with only L2 content → background generates L1 (≤200 chars overview) and L0 (frontmatter `l0` field). Both are present in the file after processing.

### SC-7: Vault Search Returns Meaningful Results

`searchNotes()` works against populated vault. Initially keyword (L0 fields + paths + tags), eventually semantic (Gemini embeddings).

**Test:** Populate vault with 5+ notes. Search "groovy commutator" → returns the concept note. Search "myk" → returns the people note. Search "nonexistent" → returns empty.

### SC-8: Existing Delta Log Memories Are Recoverable

The 8 `memory.add` deltas already in `data/deltas.jsonl` can be replayed to populate the vault.

**Test:** Read existing deltas → filter `memory.add` → replay through reducer → vault files materialize. Verify 8 notes exist in vault after replay.

## Non-Goals (This Phase)

- Semantic/vector search (Phase 3 — use keyword for now, add Gemini embeddings later)
- Wikilink graph traversal (after vault is populated)
- Forgetting/staleness policies (after extraction is solid)
- Multi-agent knowledge sharing
- Obsidian CLI integration (after vault structure is right)

## Implementation Order

1. **Scaffold vault directories** — create the directory structure
2. **SC-2 tests + implementation** — `memory.add` → `vault.write` → file on disk
3. **SC-5 tests + implementation** — MemoryTools refactor to delta-only
4. **SC-4 tests + implementation** — extraction pipeline as pure delta flow
5. **SC-3 tests + implementation** — background extraction on every message
6. **SC-6 tests + implementation** — L0/L1 auto-generation
7. **SC-8 tests + implementation** — replay existing deltas
8. **SC-7 tests + implementation** — vault search validation
9. **SC-1 validation** — full integration test

## Effect Types (New)

```typescript
// New effects the reducer can emit
type VaultEffect =
  | { type: 'vault.write'; path: string; content: string; reason: string }
  | { type: 'vault.delete'; path: string; reason: string }
  | { type: 'vault.index'; path: string }  // trigger L0/L1 regeneration

// New delta kinds
type MemoryDeltaKind =
  | 'memory.extract.requested'   // trigger background extraction
  | 'memory.extract.completed'   // extraction results
  | 'memory.add'                 // new knowledge (existing)
  | 'memory.update'              // updated knowledge (existing)
  | 'memory.delete'              // removed knowledge
  | 'memory.noop'                // extraction found nothing new
  | 'vault.written'              // file materialized to disk
  | 'vault.deleted'              // file removed from disk
  | 'vault.indexed'              // L0/L1 regenerated
```

## The Contract

After this work, every piece of knowledge Stilgar has:
1. Exists as a delta in the log (provenance)
2. Is materialized as a markdown file in the vault (human-navigable)
3. Has L0/L1 summaries for efficient context loading
4. Was derived from the unidirectional flow, never from a side-effect

No shortcuts. No `fs.writeFileSync` in business logic. Deltas in, effects out, files as materialized views.

---

*"The crystal is the log. The vault is the lens. The human and the agent look through it together."*
