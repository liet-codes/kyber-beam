# Memory Architecture

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/OTP.*

## Problem

Agents need memory that persists across sessions, grows over time, and stays useful as it scales. Most agent memory systems solve this with databases — vector stores, knowledge graphs, embedding indices. The agent remembers, but the human can't see what it knows or how it's organized.

Kyber's constraint is different: memory must be **human-navigable**. The vault is Obsidian markdown. You can open it and read your agent's mind. That's the sovereignty guarantee. But markdown files don't come with vector search or automatic fact extraction.

We need the best of both: the intelligence of modern memory systems with the transparency of a file-based vault.

## Memory System Landscape (March 2026)

| System | Architecture | Strength | Gap for Kyber |
|--------|-------------|----------|---------------|
| **OpenViking** | Filesystem paradigm, L0/L1/L2 tiered loading, recursive directory retrieval | Token-efficient context assembly, URI-addressable knowledge | Context DB only — no identity, personality, or self-maintenance |
| **Letta (MemGPT)** | OS-inspired: core/recall/archival memory tiers. Agent self-edits via function calls | Most mature self-editing agent memory | Chat-oriented, not file-backed, not human-navigable |
| **Mem0** | Extract → Compare → ADD/UPDATE/DELETE/NOOP pipeline. Graph variant for entity-relationship reasoning | Best automatic extraction pipeline | Cloud-oriented, not sovereignty-friendly |
| **Cognee** | Knowledge graph from unstructured data. SQLite + LanceDB + Kuzu, runs local | Local-first, multimodal ingestion | Python-only, pipeline-heavy |
| **Zep** | Progressive summarization, entity/intent/fact extraction, temporal search | Best conversation memory compression | Narrow scope — chat history only |

## Design: Obsidian-Native Memory with Automatic Extraction

### Core Principles

1. **Files are the source of truth.** Every memory is a markdown file in the vault. No shadow database that diverges from what the human sees.
2. **Tiered context loading.** L0/L1/L2 abstracts control token cost. The agent doesn't load full notes unless it needs them.
3. **Self-maintaining knowledge.** The vault grows and prunes itself through an extraction pipeline, not manual curation.
4. **Delta-derived.** All memory changes are deltas. The log records why every fact was added, updated, or removed.

### Memory Tiers

```
┌─────────────────────────────────────────────────┐
│  CORE MEMORY (always in context)                │
│  - SOUL.md (identity)                           │
│  - USER.md (human context)                      │
│  - Active session state                         │
│  - ~2k tokens, curated, rarely changes          │
├─────────────────────────────────────────────────┤
│  WORKING MEMORY (loaded per-conversation)       │
│  - Current conversation history                 │
│  - Recently accessed knowledge notes (L1)       │
│  - Active project context                       │
│  - ~8-16k tokens, session-scoped                │
├─────────────────────────────────────────────────┤
│  RECALL MEMORY (searchable, on-demand)          │
│  - All knowledge notes (L0 index for search)    │
│  - Conversation summaries                       │
│  - Daily memory files                           │
│  - Loaded to L1 or L2 when relevant             │
├─────────────────────────────────────────────────┤
│  ARCHIVAL MEMORY (cold storage)                 │
│  - Delta log (complete history, JSONL on disk)  │
│  - Old session transcripts                      │
│  - Compressed/archived daily files              │
│  - Queryable but never auto-loaded              │
└─────────────────────────────────────────────────┘
```

**Key insight:** Every tier is backed by markdown files, not a database. The tiers describe *loading strategy*, not storage location. A knowledge note lives in `knowledge/projects/kyber.md` regardless of which tier it's currently loaded at.

### L0/L1/L2 Tiered Loading

Every knowledge note has three representations, stored as sections within the file:

```markdown
---
type: project
created: 2026-03-15
updated: 2026-03-16
tags: [agent, harness, obsidian]
l0: "Custom agent harness with Obsidian vault. Phase 0 complete, Phase 1 in progress."
---

<!-- L1: Overview (~2k tokens) -->
## Kyber

Custom agent harness. Unidirectional dataflow: deltas → reducer → state → effects.
Phase 0 (Crystal) complete. Phase 1 (Focus): LLM plugin shipped, secrets design done.

### Key Decisions
- Secrets resolve at effect boundary, never in LLM context
- Trust rings enforce plugin capabilities

### Open Questions
- Memory extraction pipeline design

<!-- L2: Full Content (unlimited) -->
## Architecture Details

[Full content — loaded only when the agent needs deep context]
```

**L0** lives in frontmatter (`l0` field) — ~100 tokens. Used for search/ranking.
**L1** is the first content section — ~2k tokens. Used for context assembly.
**L2** is everything below — unlimited. Loaded on explicit request.

### L0/L1 Generation

L0/L1 are **auto-generated bottom-up** when L2 content changes:

1. Note is created or updated (L2 content changes)
2. Background task generates L1 summary from L2 (cheap model — Haiku)
3. L0 one-liner generated from L1
4. Frontmatter updated with new `l0` field
5. All changes recorded as deltas

This runs async via `Kyber.Memory.Consolidator`. The agent doesn't block on summarization.

### Context Assembly Pipeline

When the agent needs to respond to a message:

```
1. CORE MEMORY loaded (always)
   - SOUL.md, USER.md, session state (via Kyber.Knowledge)
   - ~2k tokens

2. CONVERSATION HISTORY loaded
   - Last N turns from current session (Kyber.Session, ETS-backed)
   - History survives restarts via delta log rehydration
   - ~4-8k tokens

3. RECALL SEARCH triggered
   - Query against L0 index (all notes)
   - Top K results loaded at L1 level
   - ~4-8k tokens

4. DEEP LOAD (optional)
   - Agent requests L2 via tool call when L1 insufficient
   - Specific notes loaded fully, on demand

5. ASSEMBLED CONTEXT → LLM
   - Total budget: ~16-32k tokens (configurable)
   - Leaves room for response generation
```

**Search implementation (Phase 1):** Keyword search against L0 fields + file paths. `Kyber.Knowledge` maintains an ETS table of note metadata including L0 abstracts.

**Search implementation (Phase 2+):** Local embeddings over L0/L1 fields for semantic search. Still file-backed — embeddings stored as a sidecar index, regenerated from vault content. Consider `Nx` + `Bumblebee` for local inference.

### Memory Extraction Pipeline (inspired by Mem0)

After every conversation (or periodically), an extraction pass runs via `Kyber.Memory.Consolidator`:

```
Conversation transcript
        │
        ▼
┌─ EXTRACT ──────────────────────────┐
│  LLM extracts candidate facts:     │
│  - New information learned          │
│  - Preference changes               │
│  - Project status updates           │
│  - Relationship context             │
│  - Decisions made                   │
└────────────────┬───────────────────┘
                 │
                 ▼
┌─ COMPARE ──────────────────────────┐
│  For each candidate fact:           │
│  1. Search existing notes (L0)      │
│  2. Find most relevant note         │
│  3. LLM decides action:            │
│     - ADD: Create new note          │
│     - UPDATE: Modify existing note  │
│     - DELETE: Remove stale info     │
│     - NOOP: Already known           │
└────────────────┬───────────────────┘
                 │
                 ▼
┌─ APPLY ────────────────────────────┐
│  Each operation becomes a delta:    │
│  - kind: "memory.add"              │
│  - kind: "memory.update"           │
│  - kind: "memory.delete"           │
│  Reducer processes deltas           │
│  Effects: write/update vault files  │
│  L0/L1 regenerated for changed     │
│  notes via Consolidator             │
└────────────────────────────────────┘
```

The extraction runs on a *cheap model* (Haiku). It's background maintenance, not the main conversation. Token cost should be minimal — we're summarizing, not reasoning.

**What gets extracted:**
- Facts about people (preferences, context, relationships)
- Project status changes (milestones, blockers, decisions)
- New concepts or frameworks discussed
- Tool/service discoveries (new APIs, new approaches)
- Decisions and their rationale

**What doesn't:**
- Casual conversation
- Transient state (weather, time-specific context)
- Anything already captured in daily memory files

### Daily Memory Files vs Knowledge Notes

Two parallel systems, different purposes:

| | Daily Files (`memory/YYYY-MM-DD.md`) | Knowledge Notes (`knowledge/**/*.md`) |
|---|---|---|
| **Purpose** | Raw event log | Curated, structured knowledge |
| **Lifecycle** | Append-only, one per day | Created/updated/deleted over time |
| **Content** | What happened today | What we know (timeless) |
| **Extraction** | Source material for extraction pipeline | Target of extraction pipeline |
| **Archival** | Compressed after 30 days | Maintained indefinitely |
| **Human use** | Journal/diary | Reference/wiki |

The extraction pipeline reads daily files and produces knowledge notes. Daily files are the *raw material*; knowledge notes are the *refined product*.

### Self-Editing via Tool Calls (inspired by Letta)

The agent can explicitly manage its own memory through tool calls:

```elixir
# Tools available to the agent for memory management
memory_search(query: string, scope: :all | :people | :projects | :concepts)
memory_read(path: string, level: :l0 | :l1 | :l2)
memory_write(path: string, content: string, reason: string)
memory_update(path: string, section: string, content: string, reason: string)
memory_forget(path: string, reason: string)
```

Every memory operation requires a `reason` — this becomes part of the delta, creating an audit trail of *why* the agent changed its own knowledge.

### Wikilink Resolution

Knowledge notes link to each other via `[[wikilinks]]`:

```markdown
<!-- knowledge/projects/kyber.md -->
Built by [[myk]] and [[liet]]. Secrets management documented in
[[2026-03-16-secrets-trust]].
```

Wikilinks serve as the **v1 knowledge graph**. Obsidian renders the graph view. For programmatic traversal, a simple regex pass over vault files builds an adjacency list.

**Future (v2/v3):** Frontmatter-typed relations, then full rhizome hyperedges. Each version is a transform over the same underlying files.

### Forgetting

Memory systems that only add are memory systems that eventually drown:

1. **Contradiction resolution:** When extraction finds a contradicting fact, the old fact is marked for review or auto-deleted (with delta logging the reason).
2. **Staleness decay:** Notes not accessed or updated in >90 days get flagged for review during memory maintenance cycles.
3. **Explicit forget:** The agent or human can explicitly forget something. The delta logs the deletion, so it's recoverable, but the note is removed from the active vault.
4. **Compression:** Daily files older than 30 days get summarized into monthly summaries. The originals move to archival.

## Implementation Phases

### Phase 1 (Current): File-Backed Tiers + Keyword Search
- Core memory always loaded (SOUL.md, USER.md) via `Kyber.Knowledge`
- Knowledge notes with L0 in frontmatter
- ETS-backed L0 index for keyword search
- Session rehydration from delta log (implemented PR #4)
- `Kyber.Memory.Consolidator` running with try/rescue error isolation
- Manual memory management via tool calls

### Phase 2: Automatic Extraction + L1 Generation
- Mem0-style extraction pipeline after conversations
- L1 auto-generated from L2 content via Consolidator
- Wikilink graph traversal for related context
- Forgetting/staleness policies active

### Phase 3: Semantic Search + Self-Improvement
- Local embeddings via `Nx` + `Bumblebee` (or external service)
- Semantic search replaces keyword search
- Extraction pipeline learns from corrections
- Multi-agent knowledge sharing (subagents contribute to shared vault)

### Phase 4: Knowledge Graph
- Frontmatter-typed relations (v2)
- Graph queries for complex reasoning
- Rhizome hyperedges (v3) when v2 hurts
- Delta-CRDT backing for potential distributed vault sync

## What We're NOT Doing

- **No external vector database.** Files + sidecar index. Sovereignty means no Pinecone dependency.
- **No cloud memory service.** Everything runs local.
- **No opaque storage.** If the agent knows it, you can read it in a markdown file.
- **No write-only memory.** Everything the agent adds, it can also update and delete.

## Connection to Other Design Docs

- **Principles** (design-principles.md): Implements Principle 2 (Files Over Databases), Principle 5 (Human-Navigable Everything), and Principle 6 (The Agent Maintains Itself).
- **Secrets** (secrets-and-trust.md): Memory operations never log secret values. Extraction pipeline sanitizes per error sanitization rules.
- **Tools** (tool-system.md): Memory tools (`memory_search`, `memory_write`, etc.) are Ring 0 builtins.
- **Observability** (observability.md): Knowledge notes carry belief provenance in frontmatter. Extraction operations tracked as deltas with DeltaMeta.

---

*"The highest function of ecology is understanding consequences." — Pardot Kynes*

*Memory without forgetting is hoarding. Memory without transparency is surveillance. Memory without human access is a black box wearing a helpful smile.*
