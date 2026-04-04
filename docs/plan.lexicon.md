# Lexicon Plan: Convergent Entity & Relation Resolution

*April 1, 2026 — From fracturing vault to convergent knowledge graph.*

## Problem

The current extraction pipeline creates new vault files for every fact, even when they're about the same entity. "Myk prefers TypeScript" and "Mykola works on Kyber" become separate files. The vault fragments instead of converging.

## Solution

A lexicon that maps surface forms to canonical entities and relations. Embeddings over keys enable fuzzy matching. Relations normalize subject-object ordering. Facts become canonical tuples.

## Architecture

### Lexicon Structure

```
vault/
  lexicon.json          # Human-readable, editable, version-controlled
  lexicon.sqlite        # Sidecar: vector index over entity/relation keys
```

**Entity Lexicon** (`lexicon.json`):
```json
{
  "entities": {
    "myk": {
      "type": "person",
      "aliases": ["mykola", "mykola_b"],
      "vault": "knowledge/people/myk.md",
      "description": "Primary human operator, AuDHD engineer"
    },
    "groovy-commutator": {
      "type": "concept", 
      "aliases": ["G(S)", "the commutator", "groovy"],
      "vault": "knowledge/concepts/groovy-commutator.md",
      "description": "Mathematical measure of non-commutativity"
    }
  }
}
```

**Relation Lexicon**:
```json
{
  "relations": {
    "employs": {
      "inverse": "employed-by",
      "aliases": ["works for", "hired by", "works at", "employed at"],
      "order": "org → person"
    },
    "prefers": {
      "inverse": "disprefers", 
      "aliases": ["likes", "favors", "enjoys", "is into", "is fond of"],
      "order": "agent → thing"
    }
  }
}
```

### Normalized Facts

| Raw Text | Canonical Tuple |
|----------|-----------------|
| "Mykola likes TypeScript" | `(myk, prefers, typescript)` |
| "TypeScript is preferred by Myk" | `(myk, prefers, typescript)` |
| "Myk works for Acme" | `(acme, employs, myk)` |
| "Acme hired Mykola" | `(acme, employs, myk)` |

Same tuple regardless of surface form. Order follows relation definition.

### Resolution Flow

```
messages arrive → buffer (5-10s or N messages)
  ↓
drain buffer → single extraction call (full transcript)
  ↓
extracted facts (batch)
  ↓
for each fact:
  - resolve subject against entity lexicon (embedding similarity)
  - resolve predicate against relation lexicon (embedding similarity)
  - resolve object against entity lexicon (embedding similarity)
  ↓
return: {resolved, candidates[], needsNewKey}
  ↓
batch comparison prompt (1 LLM call):
  "Here are the facts with their resolved entities.
   Here are close-match candidates with confidence scores.
   Confirm each resolution or specify new keys."
  ↓
memory.add/update deltas (serial processing)
  ↓
reducer → vault_write + lexicon_update effects
  ↓
vault files updated, lexicon.json updated, embeddings updated
```

### Delta Types

```typescript
type LexiconDelta =
  | { kind: 'lexicon.entity.add', payload: { key, type, aliases, vault?, description } }
  | { kind: 'lexicon.entity.update', payload: { key, aliases?, vault?, description? } }
  | { kind: 'lexicon.relation.add', payload: { key, inverse, aliases, order } }
  | { kind: 'lexicon.relation.update', payload: { key, aliases?, inverse?, order? } }
```

## Success Criteria (TDD)

### SC-L1: Entity Resolution with Embeddings

**Test:** Extract "Mykola prefers TypeScript" → resolve "Mykola" against empty lexicon → returns `needsNewKey: true`, no candidates.

**Test:** Add "myk" to lexicon with alias "mykola". Extract "Mykola prefers TypeScript" → resolve "Mykola" → returns `resolved: "myk"`, `candidates: [{entity: "myk", score: 0.94}]`, `needsNewKey: false`.

**Test:** Extract "Myk prefers strict typing" (no exact alias match) → embedding lookup finds "myk" at 0.89 similarity → returns candidate with confidence score.

**Test:** Extract "G(S) shows up in Dilla" → resolve "G(S)" against lexicon with "groovy-commutator" having alias "G(S)" → returns `resolved: "groovy-commutator"`.

### SC-L2: Relation Normalization

**Test:** Resolve "likes" against relation lexicon → returns `resolved: "prefers"` with 0.91 confidence.

**Test:** Resolve "works for" → returns `resolved: "employs"` (not the inverse). The order field determines canonical direction.

**Test:** "Myk works for Acme" → normalized to `(acme, employs, myk)` not `(myk, employs, acme)`. Relation "employs" has `order: "org → person"`.

**Test:** "Acme hired Myk" → same canonical tuple `(acme, employs, myk)` despite different surface forms.

### SC-L3: Batch Processing

**Test:** 5 messages arrive in 3 seconds → buffer accumulates → single extraction call at drain.

**Test:** Buffer drains after 10 seconds even with only 1 message → extraction fires.

**Test:** Batch of 3 facts resolves all entities in parallel (local embeddings, no LLM calls), then single comparison LLM call for the batch.

**Test:** Total LLM calls for 3-message batch: 1 extraction + 1 comparison = 2 calls (vs current 1 + 2*3 = 7 calls).

### SC-L4: Serial Processing for Convergence

**Test:** Message 1 creates `people/alice`. Message 2 mentions "Alice". Serial queue ensures message 2's resolution sees the lexicon entry from message 1.

**Test:** Parallel processing (simulated) creates duplicate entities — test proves serial is required for convergence.

**Test:** Facts within the same batch about the same entity converge to single vault update, not multiple files.

### SC-L5: Lexicon Persistence

**Test:** `lexicon.json` is valid JSON, human-readable, editable.

**Test:** `lexicon.json` is version-controlled (committed with vault changes).

**Test:** On startup, lexicon loads from `lexicon.json` + rebuilds embedding index from scratch (deterministic, no drift).

**Test:** After lexicon update, new embedding is added to sidecar store and is immediately queryable.

### SC-L6: Vault Integration

**Test:** When `lexicon.entity.add` delta processed → vault file created at `knowledge/{type}/{key}.md` with frontmatter linking to canonical key.

**Test:** When entity has existing vault file, lexicon entry's `vault` field points to it.

**Test:** `memory.add` deltas now use canonical keys in content, not surface forms.

**Test:** Search works by canonical key OR surface form (embedding lookup bridges them).

### SC-L7: Confidence & Disambiguation

**Test:** Close match (score 0.75-0.90) → returned with `needsConfirmation: true`, included in batch prompt for LLM verification.

**Test:** Low match (score < 0.75) → `needsNewKey: true`, no candidates bundled.

**Test:** Multiple candidates within 0.1 score of top → all bundled with confidence scores, LLM chooses or creates new.

**Test:** If LLM specifies new key, `lexicon.entity.add` delta emitted with surface form as initial alias.

### SC-L8: End-to-End Convergence

**Test:** 10 messages about "Myk", "Mykola", "mykola_b" over time → single vault file `people/myk.md` with all facts appended.

**Test:** 10 messages with mixed relations ("likes", "prefers", "is into") → single relation `prefers` in lexicon, normalized tuples in vault.

**Test:** Query vault for "myk" → finds facts from all surface forms. Query for "mykola" → same result via embedding lookup.

**Test:** After convergence, total vault files = number of unique entities, not number of extracted facts.

## Implementation Order

1. **SC-L1:** Entity resolution with embeddings (new module: `src/core/lexicon.ts`)
2. **SC-L5:** Lexicon persistence (JSON + SQLite sidecar)
3. **SC-L2:** Relation normalization + subject-object ordering
4. **SC-L3:** Batch processing buffer + drain mechanism
5. **SC-L4:** Serial processing queue
6. **SC-L6:** Vault integration (lexicon_update effects)
7. **SC-L7:** Confidence thresholds + disambiguation
8. **SC-L8:** Full convergence test

## Resolved Questions

1. **Embedding model:** Gemini (`gemini-embedding-001`, 3072 dims). Same as OpenClaw. API key already configured.

2. **Lexicon bootstrapping:** Seed from existing vault on first run. Scan vault files, extract entities from filenames/frontmatter, populate lexicon.json.

3. **Relation discovery:** Learn incrementally. No pre-populated relation set — relations emerge from extracted facts.

4. **Embedding refresh:** Rebuild from `lexicon.json` on every startup (simple, deterministic). Incremental on new entries during runtime.

5. **Vault file naming:** Canonical keys as filenames (`myk.md`, `groovy-commutator.md`). Human-readable and predictable.

## The Goal

After this work, the vault converges. Ten mentions of the same person across different conversations produce one rich note, not ten fragmented files. Relations normalize. Search works across surface forms. The knowledge graph grows coherently.

The lexicon is the convergence mechanism.
