# Observability

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/OTP.*

## Problem

Three different "why" questions arise with an agent:

1. **Operational:** "Why was that slow? How much did it cost?" — traditional observability
2. **Behavioral:** "Why did you do X instead of Y?" — decision tracing
3. **Epistemic:** "Why do you think X?" — belief provenance

Most agent frameworks address (1) with OTEL and ignore (2) and (3). Kyber's delta architecture lets us answer all three from the same log.

## Why Not OTEL (for now)

OTEL solves distributed tracing across microservices with vendor-neutral telemetry export. Kyber is:
- A single BEAM node (no distributed tracing needed yet)
- Not exporting to Datadog/Grafana (vault is the dashboard)
- Already producing richer events than OTEL spans (deltas carry semantic meaning)

The BEAM's `:telemetry` library is already in use (`Kyber.Web.Telemetry`). That's the right foundation. But our delta log IS the observability system — every delta already has: id (span), parent_id (trace linking), ts (timing), origin (source component), kind (operation type), payload (attributes).

If we go multi-node later (`Kyber.Distribution` is already in the supervision tree), we can bridge deltas → OTEL spans at that point.

## Delta Meta: Operational Telemetry

Every delta carries optional metadata for operational observability:

```elixir
@type delta_meta :: %{
  # Timing
  duration_ms: non_neg_integer() | nil,
  queued_ms: non_neg_integer() | nil,

  # Token usage (LLM operations)
  tokens: %{
    input: non_neg_integer(),
    output: non_neg_integer(),
    cached: non_neg_integer() | nil
  } | nil,

  # Cost
  cost: %{
    amount: float(),
    currency: String.t(),
    model: String.t() | nil,
    price_snapshot: String.t() | nil
  } | nil,

  # Errors
  error: %{
    code: String.t(),
    message: String.t(),
    retryable: boolean(),
    retry_count: non_neg_integer() | nil
  } | nil,

  # Provenance
  source: %{
    tool: String.t() | nil,
    model: String.t() | nil,
    retrieval_strategy: String.t() | nil,
    confidence_hint: String.t() | nil   # "primary" | "inferred" | "uncertain"
  } | nil
}
```

This lives on the `Delta` struct:

```elixir
defstruct [:id, :ts, :origin, :kind, :parent_id, :payload, :meta]
```

> DeltaMeta population was added in PR #5 (`Populate DeltaMeta with usage stats`). Error sanitization (auth token redaction) in PR #6.

## Operational Queries

Standard observability questions answered by delta meta:

```
"What did I spend today?"
→ filter: kind=llm.response, date=today
→ aggregate: meta.cost.amount
→ group by: meta.cost.model

"Why was that response slow?"
→ trace: follow parent_id chain from response delta
→ show: meta.duration_ms per step
→ bottleneck: step with highest duration_ms

"Which tool fails most?"
→ filter: kind=tool.error
→ group by: origin.tool_name
→ count + show: meta.error.code distribution

"Token usage this week by model"
→ filter: kind=llm.response, date=this-week
→ group by: meta.cost.model
→ aggregate: meta.tokens.{input,output,cached}
```

These queries are available via:
- `mix kyber.query` — CLI query tool
- The LiveView dashboard (`Kyber.Web.Live.DashboardLive`) — real-time view
- Direct delta store access via `Kyber.Delta.Store` — for programmatic access

**Materialized daily metrics** can be written to the vault as `knowledge/metrics/daily.md`:

```markdown
---
type: metrics
updated: 2026-03-22T21:00:00
---

# Daily Metrics — March 22, 2026

## Cost
| Category | Tokens | Cost |
|----------|--------|------|
| Conversation (opus) | 48k in / 12k out | $0.31 |
| Memory extraction (haiku) | 8k in / 2k out | $0.04 |
| **Total** | | **$0.35** |

## Performance
| Operation | p50 | p95 | Failures |
|-----------|-----|-----|----------|
| LLM call | 2.1s | 4.8s | 0 |
| web_search | 0.8s | 2.3s | 1 (429) |
```

## Behavioral Tracing: "Why did you do X?"

Decision tracing follows the delta chain to show the agent's reasoning path:

```
User asks: "Why did you search for cleaning services?"

Trace:
  message.received (Myk: "find a cheap cleaning service in columbus")
    → llm.call (context: USER.md says Ohio, message mentions columbus)
      → llm.response (tool_call: web_search)
        → tool.execute (web_search)
          → tool.result (5 results returned)
            → llm.call (results in context)
              → llm.response (formatted answer)
                → message.sent (to discord)
```

Every step is a delta with a `parent_id`. The "why" is the chain itself.

For significant decisions, the LLM's reasoning can be captured as a delta:

```elixir
%Delta{
  kind: "agent.reasoning",
  parent_id: "the-llm-response-delta",
  payload: %{
    thought: "User needs cleaning service before Saturday move. Prioritizing cheap options.",
    alternatives_considered: ["TaskRabbit only", "ask for budget first"],
    chosen: "broad search, present options with pricing"
  }
}
```

This is opt-in — expensive to capture for every turn, but valuable for significant decisions.

## Epistemic Provenance: "Why do you think X?"

The deepest observability question. Not "what did you do" but "what do you believe and why."

### Belief Chain

Every fact in the vault has an origin story traceable through deltas:

```
Belief: "Taalas HC1 does 17,000 tokens/second"

Provenance:
┌─ Origin ──────────────────────────────────────────────┐
│ Delta: tool.result (web_search, 2026-03-16 18:47)     │
│ Source: wccftech.com, medium.com articles              │
│ Confidence: primary (direct from source)               │
└───────────────────────────────────────────────────────┘
        │
        ▼
┌─ Extraction ──────────────────────────────────────────┐
│ Delta: memory.add (2026-03-16 18:48)                  │
│ Extracted by: haiku extraction pipeline                │
│ Stored in: knowledge/tools/taalas.md                   │
└───────────────────────────────────────────────────────┘
        │
        ▼
┌─ Current State ───────────────────────────────────────┐
│ File: knowledge/tools/taalas.md                        │
│ Section: "## Performance"                              │
│ Last verified: 2026-03-16                              │
│ Contradictions: none                                   │
└───────────────────────────────────────────────────────┘
```

### Implementing Belief Provenance

Knowledge notes carry provenance in frontmatter:

```markdown
---
type: tool
name: taalas
sources:
  - delta: "abc123"
    date: 2026-03-16
    type: web_search
    url: "https://wccftech.com/..."
    confidence: primary
  - delta: "def456"
    date: 2026-03-16
    type: web_search
    confidence: reinforcing
contradictions: []
last_verified: 2026-03-16
citation_count: 3
---
```

The extraction pipeline (`Kyber.Memory.Consolidator`) populates this automatically when creating or updating knowledge notes.

### The `why_believe` Tool

```elixir
# Ring 0 builtin tool
def why_believe(%{"query" => query, "depth" => depth}) do
  # 1. Search knowledge notes for the belief
  # 2. Read the `sources` frontmatter
  # 3. Follow delta IDs back to origin in the delta store
  # 4. Return the provenance chain
end
```

### Confidence Levels

| Level | Meaning | How it happens |
|-------|---------|----------------|
| `uncertain` | Agent inferred this, no source | LLM reasoning without tool verification |
| `primary` | Single source | One tool result or one conversation |
| `reinforced` | Multiple independent sources | Multiple searches, conversations confirm |
| `verified` | Human confirmed | Myk edited the note or explicitly confirmed |
| `contradicted` | Conflicting information exists | Two sources disagree; flagged for review |
| `stale` | Not verified recently | >90 days since last_verified, auto-flagged |

## Materialization: The Dashboard

All three observability layers materialize into:

**Vault notes** (persistent, human-navigable):
```
knowledge/
├── metrics/
│   ├── daily.md          # Cost, tokens, performance (auto-updated)
│   ├── weekly.md         # Aggregated weekly summary
│   └── monthly.md        # Trends, anomalies
│
└── (every knowledge note carries its own provenance in frontmatter)
```

**LiveView dashboard** (real-time, via Phoenix PubSub + delta stream):
- `Kyber.Web.Live.DashboardLive` subscribes to delta store
- Real-time tool calls, LLM responses, errors
- BEAM health (process count, memory, schedulers)
- Cron job status
- See DASHBOARD_PLAN.md for full spec

No external dashboard needed. The vault is the long-term dashboard. LiveView is the real-time view.

## Implementation Phases

### Phase 1 (Current): Delta Meta
- `DeltaMeta` in Delta struct ✓ (PR #5)
- LLM plugin populates tokens/cost/duration ✓
- Error sanitization strips credentials ✓ (PR #6)
- LiveView dashboard for real-time delta stream ✓

### Phase 2: Belief Provenance
- Extraction pipeline writes `sources` frontmatter on knowledge notes
- Delta IDs linked to knowledge note creation/updates
- Confidence levels tracked and updated
- `why_believe` tool available to agent

### Phase 3: Behavioral Tracing
- `agent.reasoning` deltas for significant decisions
- Trace visualization (text-based, in vault notes or LiveView)
- Decision audit trail for external actions

### Phase 4: Dashboard + Queries
- Materialized metrics notes (daily/weekly/monthly) via cron job
- Delta query tool for ad-hoc investigation
- Anomaly detection (cost spikes, unusual failure rates)
- Optional: `:telemetry` span export for external tools if multi-node

## What We're NOT Doing

- **No external observability platform as a dependency.** Vault notes are the long-term dashboard.
- **No real-time metrics streaming to third parties.** LiveView is the real-time view.
- **No black-box evaluation.** Every belief is traceable. No "the model just thinks that."

## Connection to Other Design Docs

- **Principles** (design-principles.md): Implements Principle 1 (The Delta Is the Atom) and Principle 8 (Observability Is Not Optional).
- **Memory** (memory-architecture.md): Extraction pipeline populates provenance frontmatter. Confidence levels inform retrieval ranking.
- **Secrets** (secrets-and-trust.md): Observability never logs secret values. Error sanitization (PR #6) applies before DeltaMeta is written.
- **Tools** (tool-system.md): Every `tool.result` and `tool.error` delta carries DeltaMeta. Tool knowledge notes accumulate failure patterns.

---

*"The question is not whether the agent is right. The question is whether the agent can show you why it thinks it's right — and whether you can follow the thread back to reality."*
