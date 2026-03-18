# Kyber-BEAM — Planning Document

## What Is This?
Elixir/OTP port of Kyber, a personal agent harness. The TypeScript prototype validated the architecture (delta-driven unidirectional dataflow). Now we're putting it on the substrate it was always meant for.

## Why BEAM?
- **Distribution is native** — `Node.connect/1` and processes talk across machines transparently
- **Supervision trees** — fault tolerance we were hand-building in TS comes free
- **Hot code reload** — plugin system without restarts
- **Process isolation** — channel agents can't crash each other
- **Pattern matching** — the reducer is literally just function clauses
- **Lightweight processes** — millions of concurrent agents, not threads

## Architecture (OTP)

```
Kyber.Application (Application)
├── Kyber.Core (Supervisor)
│   ├── Kyber.Delta.Store (GenServer)
│   │   └── Append-only JSONL log + PubSub via Registry
│   ├── Kyber.State (Agent)
│   │   └── Holds current KyberState, updated by reducer
│   ├── Kyber.Effect.Executor (GenServer)
│   │   └── Dispatches effects to registered handlers
│   ├── Kyber.Plugin.Manager (DynamicSupervisor)
│   │   └── Each plugin is a supervised child process
│   └── Kyber.Task.Supervisor (Task.Supervisor)
│       └── Async effect execution
├── Kyber.Web (Supervisor)
│   └── Bandit HTTP server
│       ├── GET /health
│       ├── GET /api/deltas (query)
│       ├── POST /api/deltas (emit)
│       └── WS /ws (delta stream)
└── Kyber.Registry (Registry)
    └── PubSub for delta subscribers
```

## Core Types

```elixir
# Delta
%Kyber.Delta{
  id: String.t(),
  ts: integer(),
  origin: Kyber.Delta.Origin.t(),
  kind: String.t(),
  payload: map(),
  parent_id: String.t() | nil
}

# Origin (tagged tuples)
{:channel, channel, chat_id, sender_id}
{:cron, schedule}
{:subagent, parent_delta_id}
{:tool, tool}
{:human, user_id}
{:system, reason}

# Effect
%{type: atom(), ...}

# State
%Kyber.State{
  sessions: %{String.t() => Kyber.Session.t()},
  plugins: [String.t()],
  errors: [Kyber.Error.t()]
}
```

## Data Flow

```
External Event (Discord msg, HTTP, cron)
    ↓
Delta created (with origin, kind, payload)
    ↓
DeltaStore.append(delta)
    → persists to JSONL
    → broadcasts via Registry PubSub
    ↓
Reducer.reduce(state, delta) → {new_state, effects}
    → pure function, no side effects
    → pattern matches on delta.kind
    ↓
State updated (Agent.update)
    ↓
Effects dispatched (Task.Supervisor.async)
    → :llm_call → Anthropic API → emits llm.response delta
    → :send_message → Discord/channel → emits message.sent delta
    → :error → emits error delta
```

## Phases

### Phase 0 — Crystal (Current Sprint)
- [x] Mix project with supervision tree
- [ ] Delta struct + Store GenServer (JSONL + PubSub)
- [ ] Reducer (pure function module)
- [ ] Effect Executor
- [ ] Plugin Manager (DynamicSupervisor)
- [ ] Web server (Bandit + Plug.Router)
- [ ] ExUnit tests for all modules
- [ ] GitHub repo + push

### Phase 1 — Focus
- [ ] LLM plugin (Anthropic API via Req, OAuth token support)
- [ ] Session management (conversation history as deltas)
- [ ] Discord plugin (gateway WebSocket + REST)
- [ ] Basic CLI (Mix task or escript)

### Phase 2 — Liquid
- [ ] Multi-node distribution (connect BEAM nodes across minis)
- [ ] Shared inference via exo integration
- [ ] Phoenix LiveView dashboard (replaces Mission Control)
- [ ] Hot code deployment across cluster

### Phase 3 — Rhizome
- [ ] Knowledge graph (Obsidian vault integration)
- [ ] Familiard as a BEAM node
- [ ] Autoresearch integration
- [ ] Voice pipeline plugin

## Key Design Decisions

1. **Reducer stays pure** — no GenServer, no side effects. Just `reduce(state, delta) -> {state, effects}`. Testable, predictable, debuggable.

2. **Plug, not Phoenix** — Phase 0 uses Plug + Bandit directly. Phoenix is Phase 2 when we need LiveView. Don't import the world before you need it.

3. **Registry for PubSub** — no external deps (Redis, RabbitMQ). Registry is built into OTP and handles pub/sub beautifully.

4. **Tagged tuples for origins** — Elixir pattern matching makes this natural. No need for union types or discriminated unions.

5. **Task.Supervisor for effects** — effects are fire-and-forget async tasks under supervision. If one fails, it doesn't cascade.

## From TS to Elixir — Translation Guide

| TypeScript | Elixir |
|-----------|--------|
| class DeltaStore | GenServer + ETS/file |
| reduce(state, delta) | Kyber.Reducer.reduce/2 (pure module) |
| class EffectExecutor | GenServer + handler registry |
| class PluginManager | DynamicSupervisor |
| Express + ws | Plug.Router + Bandit + WebSockAdapter |
| new Promise() | Task.async / GenServer.call |
| EventEmitter | Registry PubSub |
| try/catch | {:ok, _} / {:error, _} + supervisors |
| interface/type | @type / defstruct |

## Dependencies (Minimal)
- `jason` — JSON encoding/decoding
- `bandit` — HTTP server (lighter than Cowboy)
- `plug` — HTTP routing
- `websock_adapter` — WebSocket support for Plug
- `req` — HTTP client (for Anthropic API, Phase 1)

---

*"The BEAM is the territory." — Liet, March 2026*
