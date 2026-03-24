# Design Principles

*The rules that govern every other design doc.*

> Ported from the TypeScript kyber design repo (2026-03-16). Adapted for Elixir/OTP.

## 1. The Delta Is the Atom

Everything that happens produces a delta. Everything that is known was produced by a delta. The delta log is the source of truth. Current state is a materialized view. If it's not in the log, it didn't happen.

**In Elixir/OTP terms:** `Kyber.Delta.Store` is the append-only JSONL log. `Kyber.State` (an Agent) is the materialized view. `Kyber.Reducer` is the pure function that transforms `(state, delta) → new_state + effects`. `Kyber.Effect.Executor` handles effects and re-enters results as new deltas.

**Corollaries:**
- No side-channel mutations. No action-at-a-distance.
- Every state change is traceable to its cause via `parent_id`.
- Replay the log, get the same state.
- The log is append-only. Deltas are immutable once written.
- Errors are deltas too — `error.route`, `error.uncaught`, `plugin.failed`.

## 2. Files Over Databases

Knowledge lives in markdown files. Configuration lives in markdown files. The vault is navigable by humans in Obsidian and by the agent through tools. No opaque storage. No shadow state.

**In Elixir/OTP terms:** `Kyber.Knowledge` serves vault files. The delta log is JSONL on disk. `priv/vault` (symlinked to `~/.kyber/vault`) is the single source of knowledge truth. ETS caches are read-through — always derivable from disk.

**Corollaries:**
- If the agent knows it, you can read it in a file.
- If you edit a file, the agent sees the change.
- Git provides versioning, backup, and sync. No separate persistence layer.
- Sidecar indices (embeddings, search) are derived from files, not the other way around.

## 3. Boundaries at the Effect Executor

The reducer is pure. The LLM is untrusted. The effect executor is the boundary where secrets are resolved, capabilities are checked, and the real world is touched. All security, all I/O, all side effects flow through this single chokepoint.

**In Elixir/OTP terms:** `Kyber.Reducer` is a pure function — no I/O, no side effects, no GenServer calls. It returns `{:ok, new_state, effects}`. `Kyber.Effect.Executor` (a GenServer) dispatches effects, resolves secrets, calls tools, emits results as new deltas. This is the trust boundary.

**Corollaries:**
- The LLM never holds secret values.
- Tool results enter as deltas, not return values.
- Error sanitization happens at the boundary.
- Trust enforcement happens at the boundary.

## 4. Sovereignty Over Convenience

No cloud dependencies for core functionality. No vendor lock-in for data formats. No services that stop working when someone else's server goes down. External services are optional accelerators, not load-bearing walls.

**Corollaries:**
- The vault works offline. The agent works without internet (with a local model).
- Migration away from any component is always possible.
- Data export is trivial — it's already files.
- Authentication tokens come from the user's accounts, not ours.

## 5. Human-Navigable Everything

The agent's knowledge, metrics, configuration, and reasoning are all legible to humans. Not through a dashboard API — through files you can open and read. Obsidian is the shared cognitive space.

**In Elixir/OTP terms:** The LiveView dashboard (`Kyber.Web.Live.DashboardLive`) renders what's already in the delta stream — no additional data layer. Knowledge notes have L0/L1/L2 tiers for both agent efficiency and human scanning.

**Corollaries:**
- Knowledge notes have L0/L1/L2 tiers for both agent efficiency and human scanning.
- Tool compositions are readable workflow documents, not code.
- Belief provenance is frontmatter on the note, not a database query.
- The graph view in Obsidian visualizes the agent's understanding.

## 6. The Agent Maintains Itself

Memory grows through automatic extraction. Knowledge notes stay current through update/delete cycles. Stale information decays. Tool knowledge accumulates from usage. The vault is a garden, not a warehouse.

**In Elixir/OTP terms:** `Kyber.Memory.Consolidator` handles background extraction. It runs as an OTP worker with its own ETS pool for scoring tasks. It is intentionally isolated from the core pipeline — slow extraction never blocks fast conversation response.

**Corollaries:**
- Extraction pipeline runs after conversations (cheap model, background).
- Forgetting is a feature. Contradiction resolution is active.
- Tool quirks are learned, not hardcoded.
- Confidence levels track how well-sourced a belief is.

## 7. Plugins All the Way Down

Channels, tools, LLM providers, TTS, memory backends — all plugins. Same interface, same lifecycle, same hot-reload. Adding a capability means registering a plugin, not modifying core.

**In Elixir/OTP terms:** `Kyber.Plugin.Manager` is a `DynamicSupervisor`. Plugins implement a behaviour with `init/1`, `handle_effect/2`, `shutdown/1`. Currently `Plugin.LLM` and `Plugin.Discord` are started directly in the application supervisor (known inconsistency — see ARCHITECTURE_AUDIT.md). Goal is full plugin-manager parity.

**Corollaries:**
- Core is small. Plugins are where features live.
- Third-party tools enter through adapters.
- Trust rings control what each plugin can access.
- Plugin manifests declare secrets and capabilities upfront.

## 8. Observability Is Not Optional

Every delta carries provenance metadata. Every belief is traceable to its source. Every cost is tracked. Not because we're building an enterprise product — because an agent you can't inspect is an agent you can't trust.

**In Elixir/OTP terms:** `DeltaMeta` is embedded in every delta — timing, token usage, cost, error codes, source provenance. The LiveView dashboard subscribes to the delta stream via `Phoenix.PubSub`. The vault IS the dashboard for deep history; LiveView is the dashboard for real-time state.

**Corollaries:**
- DeltaMeta on every delta: timing, tokens, cost, errors, source.
- "Why do you think X?" is always answerable.
- "How much did that cost?" is always answerable.
- The vault IS the long-term dashboard. LiveView is the real-time view.

## 9. Design for the Upgrade Path

Not everything ships in Phase 1. But everything designed today must have a clean upgrade path. Keyword search that can become vector search. File-backed tiers that can gain embedding indices. In-process tools that can be sandboxed later. No dead ends.

**In Elixir/OTP terms:** OTP process isolation naturally supports the upgrade path. A tool running in a `Task` can be moved to a `GenServer` or a separate node without changing its interface. Distribution (`Kyber.Distribution`) is in the tree now, even if only one node runs today.

**Corollaries:**
- Interfaces are designed for the future, implementations are built for today.
- Distributed Elixir (multi-node) is an option, not a requirement.
- BEAM telemetry (`:telemetry`) is available as a bridge to external observability if needed.
- Knowledge graph (v3 wikilinks → typed relations → rhizome hyperedges) builds on v1 without migration.

## 10. Build Less, Know More

The docs are thicker than the code. That's on purpose. Design decisions are cheap to change on paper. Code changes have momentum. When in doubt, write a doc, discuss it, then build the minimum that tests the assumption.

**Corollaries:**
- Phase 1 is small. Hardcoded tools, keyword search, manual memory curation.
- Complexity is earned, not assumed.
- If a feature isn't needed yet, it's documented but not built.
- The code should be boring. The architecture should be interesting.

---

## Delta Kind Convention

All delta kinds use dot-separated namespaces, consistently across all docs and code:

```
message.received    message.sent
llm.call            llm.response
tool.execute        tool.result       tool.error
memory.add          memory.update     memory.delete
agent.reasoning
error.route         error.uncaught    error.unhandled
plugin.loaded       plugin.failed
system.snapshot     system.updated    system.restarting
cron.fired
tag.apply           tag.revise
task.start          task.end
```

## Secret Name Convention

Secret names mirror plugin paths: `{plugin}.{service}.{key}[.{environment}]`

```
llm.anthropic.token
llm.anthropic.token.staging
tts.elevenlabs.key
channel.discord.token
channel.discord.token.dev
```

---

*These principles are ordered by priority. When two conflict, the higher-numbered one yields. The delta is sacred. Files are sovereign. Boundaries are inviolable. Everything else is negotiable.*
