# Context & Tags

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/OTP.*

## Why Kyber Has No Sessions

Most agent frameworks organize conversations into sessions — bounded containers that hold a sequence of messages. Sessions feel natural: a conversation starts, things happen, it ends.

But reality isn't that neat:

- A conversation about Kyber starts in Discord DMs and continues in a voice call
- A single message is relevant to both a research task AND a scheduling question
- You go to bed, wake up, and continue the same thread — did the "session" end?
- A subagent's result feeds into two different contexts
- A topic shift mid-conversation doesn't mean a new conversation started

Sessions are **arborescent** — tree-structured containers where each thing belongs to exactly one parent. Conversations are **rhizomatic** — any point can connect to any other point through multiple paths. Forcing rhizomatic reality into arborescent containers creates artificial boundaries, orphan problems, and lifecycle complexity that serves the framework, not the user.

> **Note on current implementation:** `Kyber.Session` exists and currently uses Discord `chat_id` as a session key. This is a pragmatic Phase 1 implementation — it provides channel isolation. The tag-based model described here is the target architecture; sessions are the stepping stone.

Kyber's goal is: **deltas, tags, and queries** instead of sessions.

## The Model

```
Deltas ──── immutable atoms of what happened (Principle 1)
Tags ────── deltas about deltas (connections, classifications, associations)
Channels ── persistent addresses where messages arrive
Tasks ───── bounded work with goals (a special tag with lifecycle)
Context ─── assembled per-turn by querying the delta graph
```

### Deltas: What Happened

Deltas record events. They are immutable once written. They link to causal parents via `parent_id`. They carry no classification, no session ID, no topic tag at creation time.

```elixir
%Delta{
  id: "d1",
  ts: 1773707000000,
  kind: "message.received",
  parent_id: "d0",
  origin: %{type: "channel", channel: "discord:dm"},
  payload: %{text: "what about kyber's memory architecture?"}
  # No tags. No session. Just what happened.
}
```

A delta knows what caused it (`parent_id`) and where it came from (`origin`). That's all it needs to know about itself.

### Tags: Connections After the Fact

Tags are deltas that annotate other deltas. They're applied by tagging services — not baked in at creation time. This means:

- Deltas stay truly immutable
- Tags can be wrong and corrected (new tag delta supersedes old)
- Multiple taggers can run with different strategies
- Tags can be applied retroactively

```elixir
%Delta{
  id: "t1",
  kind: "tag.apply",
  parent_id: "d1",          # the delta being tagged
  origin: %{type: "tagger", name: "auto-topic"},
  payload: %{
    channel: "discord:dm:353690689571258376",
    topics: ["kyber", "memory-architecture"],
    entities: ["myk", "liet"],
    task: nil               # not part of a bounded task
  },
  meta: %{
    source: %{tool: "auto-tagger", model: "haiku"},
    confidence: "primary"
  }
}
```

**Tag types** (not a closed set — new types can emerge):

| Tag Type | What It Means | Lifecycle |
|----------|--------------|-----------|
| `channel` | Where this delta appeared | Persistent address, set by channel adapter at origin |
| `topic` | What this delta is about | Emergent, no lifecycle, clustering signal |
| `entity` | Who/what is mentioned | Extracted by tagger, links to knowledge notes |
| `task` | Which bounded goal this serves | Has start/end, can be "active" or "complete" |
| `project` | Which long-running project | Broader than task, links to project knowledge notes |
| `mood` | Emotional tone | Optional, useful for voice/personality tuning |

### Tagging Services

Tags are produced by services that run at different speeds and costs:

**Immediate (at delta creation):**
- Channel adapter sets `channel` tag on origin — the one tag that's known at write time (but still a separate tag delta, not a field on the source delta)

**Fast (synchronous, cheap):**
- Keyword matcher — scans delta payload for known entity/topic keywords
- Task matcher — checks if delta's `parent_id` chain connects to an active task
- Channel carry-forward — inherits channel tag from parent delta

**Background (async, LLM-powered):**
- Topic extraction — cheap model analyzes delta content, assigns topic tags
- Entity extraction — identifies people, tools, concepts mentioned
- Sentiment/mood — classifies emotional tone
- Retroactive re-tagging — periodic pass re-evaluates old deltas with new context

**Human:**
- Manual tagging via Obsidian/vault edits
- Explicit commands ("tag this as part of the kyber project")

In Elixir, tagging services are OTP workers that subscribe to the delta stream via `Phoenix.PubSub` and emit `tag.apply` deltas.

### Tag Correction

Tags can be wrong. Correction is just another delta:

```elixir
# Original tag
%Delta{kind: "tag.apply", parent_id: "d1", payload: %{topics: ["cuties"]}}

# Correction (later, different tagger or human)
%Delta{kind: "tag.revise", parent_id: "d1", payload: %{topics: ["kyber"]}}
```

`tag.revise` supersedes `tag.apply` for the same delta. No mutation of the original — just a newer opinion in the log.

### Channels: Where Messages Flow

A channel is a persistent address. Messages arrive there. It's the stable reference that outlives any conversation.

```
discord:dm:353690689571258376              — DMs with Myk
discord:guild:1466661116036911159:general  — sich #general
cron:morning-briefing                      — scheduled job
task:research-taalas                       — subagent delivery address
```

Channels are just a tag type — but a special one because channel adapters use them for routing. When a message arrives on Discord, the adapter:

1. Creates a `message.received` delta
2. Emits a `tag.apply` delta with `channel: "discord:dm:..."`
3. Context assembly queries recent deltas with this channel tag

No session lookup. No "find or create session." Just: what happened recently on this channel?

### Tasks: Bounded Work

A task is a tag with lifecycle semantics. It has a goal, a start, and a completion. Subagents run tasks. Cron jobs are tasks.

```elixir
# Task start
%Delta{
  kind: "task.start",
  payload: %{
    id: "research-taalas",
    goal: "Find pricing and availability for Taalas HC1",
    model: "haiku",
    deliver_to: %{channel: "discord:dm:353690689571258376"}
  }
}

# Work deltas get tagged with the task
%Delta{kind: "tag.apply", parent_id: "work-delta-1", payload: %{task: "research-taalas"}}

# Task completion
%Delta{
  kind: "task.end",
  payload: %{
    id: "research-taalas",
    summary: "No retail pricing yet. HC2 expected winter 2026.",
    cost: %{amount: 0.04, currency: "USD"}
  }
}
```

Tasks are the only thing with explicit lifecycle. Channels don't end. Topics don't end. But tasks do — because they have goals, and goals are either met or abandoned.

### Context Assembly: Pure Query

When the agent needs to respond, context is assembled by querying the delta graph:

```
Input: new message on channel X

1. CORE MEMORY (always loaded)
   → SOUL.md, USER.md (via Kyber.Knowledge)
   → ~2k tokens

2. CHANNEL HISTORY (recent deltas tagged with channel X)
   → Last N deltas on this channel
   → Compressed summary of older deltas on this channel
   → ~8-16k tokens

3. ACTIVE TASKS (deltas tagged with active tasks relevant to this channel)
   → If there's an active task on this channel, include recent task context
   → ~2-4k tokens

4. KNOWLEDGE RECALL (search by topic tags + message content)
   → Query L0 index with topic tags from recent deltas
   → Load matched notes at L1
   → ~4-8k tokens

5. CROSS-CHANNEL CONTEXT (optional, when topics span channels)
   → If topic tags on this message match recent deltas on OTHER channels,
     include brief context from those channels
   → "You were discussing this in wet-math #general yesterday"
   → ~1-2k tokens

6. ASSEMBLE → budget to context window → send to LLM
```

**Step 5 is the rhizomatic payoff.** Because tags connect deltas across channels, the agent naturally knows that a conversation in DMs is related to one in wet-math. Sessions would have made this impossible — cross-session context is an oxymoron. Cross-channel context is just a tag query.

### Compression: Sliding Window Over the Stream

The channel stream is potentially infinite. Context windows are not.

```
Channel stream: [d1, d2, d3, ... d500, ... d1000]

Context window sees:
  [compressed summary of d1-d800] + [d801-d1000 in full]

When d1000+ arrives:
  [compressed summary of d1-d900] + [d901-d1050 in full]
```

Compression is a background process that periodically summarizes older deltas on a channel into `summary.channel` deltas. The summaries are themselves deltas — tagged with the channel, queryable, replaceable.

Compression doesn't delete anything. The full deltas stay in the log forever.

In Elixir, the compression service can be a GenServer on a timer, or triggered by `Kyber.Cron`.

### The Tag Index

Querying the delta log by tags needs to be fast. A sidecar ETS table (or JSONL index) maps tags to delta IDs:

```elixir
# Derived from tag.apply deltas, rebuilt on startup
# ETS table: {tag_type, tag_value} → [delta_id, ...]
:ets.lookup(:tag_index, {:channel, "discord:dm:353690689571258376"})
# => [{:channel, "discord:dm:..."}, ["d1", "d3", "d5", ...]}]
```

Derived, not authoritative. Rebuilt from the delta log if corrupted. Updated incrementally as new tag deltas arrive.

## What This Replaces

| Traditional Concept | Kyber Equivalent |
|-------------------|-----------------|
| Session | Channel tag + recency query |
| Session start/end | Nothing (channels persist, tasks have lifecycle) |
| Session config | Channel config as a delta |
| Conversation history | Deltas tagged with channel, compressed over time |
| Subagent session | Task with `deliver_to` |
| Cross-session context | Cross-channel tag query (topic overlap) |
| Session timeout | Compression (no timeout, just sliding window) |

## Connection to Other Design Docs

- **Principles** (design-principles.md): Implements Principle 1 (The Delta Is the Atom) to its logical conclusion — even metadata about deltas is deltas.
- **Memory** (memory-architecture.md): The extraction pipeline IS a tagging service. It reads deltas, extracts facts (→ knowledge notes) AND applies tags (→ topic/entity classification).
- **Observability** (observability.md): Tag provenance (which tagger, what confidence) feeds into belief provenance.
- **Tools** (tool-system.md): Tagging services are plugins. You could install a custom tagger for domain-specific classification.

## Implementation Phases

### Phase 1 (Current): Channel Tags + Keyword Tagger
- Channel adapter emits channel tags on message deltas
- `Kyber.Session` provides channel isolation via `chat_id` key (stepping stone)
- Simple keyword tagger for known topics/entities
- Context assembly queries by channel tag + recency
- Tasks as manually created `task.start`/`task.end` deltas

### Phase 2: LLM Tagger + Cross-Channel
- Background topic/entity extraction via cheap model
- Cross-channel context assembly (topic overlap detection)
- Compression service for long-running channels
- ETS tag index for fast queries
- Migrate from session-keyed to channel-tag-keyed context assembly

### Phase 3: Retroactive Tagging + Learning
- Periodic re-tagging of old deltas with new context
- Tag quality feedback (corrections improve tagger)
- Tag-based cost attribution ("how much did the kyber project cost this month?")

---

*"A rhizome has no beginning or end; it is always in the middle, between things, interbeing, intermezzo." — Deleuze & Guattari*

*Sessions are trees. Tags are rhizomes. The delta stream is the plane of immanence. Context is assembled, not contained.*
