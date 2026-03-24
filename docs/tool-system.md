# Tool System

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/OTP.*

## Problem

The agent needs tools — web search, file operations, API calls, TTS, camera, memory management. We need a tool system that:

1. Works with a simple base standard (so anyone can write tools)
2. Extends to a richer superset for deep Kyber integration
3. Adapts existing ecosystems without locking in
4. Learns from tool usage over time

## Design: Tools Are Plugins That Register Effect Handlers

In Kyber's architecture, tools aren't a separate system — they're plugins that register themselves as available tools and handle the resulting effects.

```
LLM sees:     tool definitions (name, description, schema)
LLM emits:    tool_call in response
Reducer:      creates tool.execute effect
Plugin:       handles effect, executes tool logic
Result:       re-enters as tool.result delta (with DeltaMeta for timing/cost)
```

This means the tool system is already built — it's the plugin + effect system from the core architecture. "Adding a tool" means registering a plugin. No new abstractions needed.

In Elixir: `Kyber.Tools` holds tool definitions, `Kyber.ToolExecutor` dispatches, and `Kyber.Effect.Executor` wires it together.

## The Base Standard

Any tool that provides these things can be installed in Kyber:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()  # JSON Schema
@callback execute(input :: map()) :: {:ok, result :: map()} | {:error, reason :: String.t()}
```

Deliberately minimal. A tool is a typed function with metadata.

> **Note:** The `execute/1` return value is for the adapter layer. Internally, all tool results are emitted as `tool.result` deltas with DeltaMeta (timing, cost, provenance). `Kyber.ToolExecutor` wraps the return value into a delta — tool authors don't need to know about deltas unless they opt into the Kyber superset.

## The Kyber Superset

Tools that want deeper integration can implement the full plugin behaviour:

```elixir
@callback name() :: String.t()
@callback description() :: String.t()
@callback parameters() :: map()
@callback execute(input :: map(), context :: tool_context()) :: {:ok, map()} | {:error, String.t()}

# Lifecycle (optional callbacks)
@callback init(kyber :: pid()) :: :ok | {:error, term()}
@callback shutdown() :: :ok
@callback reload() :: :ok

# Delta awareness (optional)
@callback on_delta(delta :: Delta.t()) :: :ok
# core calls emit_delta/1 on the plugin module to give it an emit function

# Security manifest (required for non-builtin)
@callback secrets() :: [String.t()]       # e.g. ["tts.elevenlabs.key"]
@callback capabilities() :: [capability()]
@callback trust() :: trust_ring()

# Knowledge
@callback knowledge_path() :: String.t() | nil
```

```elixir
@type capability :: :filesystem | :network | :exec | :camera | :audio | :notifications | :secrets
@type trust_ring :: :builtin | :verified | :community | :untrusted

@type tool_context :: %{
  session_id: String.t(),
  resolve: (String.t() -> {:ok, String.t()} | {:error, term()}),
  emit: (map() -> :ok),
  log: (String.t(), String.t() -> :ok)
}
```

### What the superset enables:

- **Lifecycle hooks** — tools that need connections (Discord, external APIs) init on startup, clean up on shutdown, hot-reload when config changes
- **Delta awareness** — tools can react to system events (e.g., a monitoring tool watches for error deltas)
- **Secret scoping** — tool declares what secrets it needs, executor only resolves those
- **Capability declaration** — explicit about what system resources are needed
- **Knowledge path** — points to a vault note where the agent accumulates usage context

## Trust Rings

```
┌─── Ring 0: Builtin ──────────────────────────┐
│  memory_search, memory_write, vault_read,     │
│  delta_query, llm_call                        │
│                                               │
│  Full trust. Direct delta access.             │
│  Cannot be uninstalled. Part of core.         │
├─── Ring 1: Verified ─────────────────────────┤
│  Tools you wrote or personally audited.       │
│  tts, camera, discord, github, web_search     │
│                                               │
│  Secret access per manifest.                  │
│  Full plugin interface available.             │
│  Installed from local path or trusted repo.   │
├─── Ring 2: Community ────────────────────────┤
│  Installed from registry or external sources. │
│                                               │
│  Base standard interface only.                │
│  No direct secret access (proxy or approval). │
│  Capability enforcement active.               │
├─── Ring 3: Untrusted ────────────────────────┤
│  One-shot tools from external agents or       │
│  unaudited sources.                           │
│                                               │
│  Fully sandboxed. No persistence.             │
│  No vault access. No secret access.           │
│  BEAM process isolation when available.       │
└──────────────────────────────────────────────┘
```

Ring assignment is explicit in the tool's manifest, verified by the installer. Community tools can be promoted to verified after audit.

**In Elixir:** BEAM's process model provides natural isolation for untrusted tools — run them in a separate supervised process with limited capabilities, catch all exits.

## Tools as Knowledge

Every tool (Ring 1+) gets a vault note in `knowledge/tools/`:

```markdown
---
type: tool
name: web_search
trust: verified
secrets: [tool.brave.api_key]
capabilities: [network]
installed: 2026-03-16
last_used: 2026-03-16T20:30:00
usage_count: 47
failure_rate: 0.02
---

# web_search

Searches the web via Brave Search API.

## Quirks (learned)
- Rate limited to 10 req/min on free tier
- Returns poor results for queries > 200 chars
- Better for technical topics than current events

## Usage Patterns
- Prefer specific, focused queries
- Chain with web_fetch for full page content

## Failure Log
- 2026-03-14: 429 errors during batch research (hit rate limit)
```

**How this works:**
1. Tool is installed → knowledge note created from manifest metadata
2. Agent uses tool → `usage_count` and `last_used` updated (background delta)
3. Tool fails → failure logged, `failure_rate` updated
4. Agent notices patterns → adds to "Quirks" section via `memory_write`
5. Extraction pipeline picks up tool insights from conversations → auto-updates notes

**The result:** The agent's tool usage improves over time not because the tool code changes, but because the agent's *understanding* of the tool deepens.

## Tool Composition

Complex workflows can be composed from atomic tools. Compositions are defined as vault notes:

```markdown
---
type: tool-composition
name: deep_research
description: "Research a topic thoroughly and save findings"
trust: verified
---

# deep_research

## Steps

1. **Search** — `web_search(query: $topic)` → `$urls`
2. **Fetch** — for each url in `$urls`: `web_fetch(url: $url)` → `$pages[]`
3. **Synthesize** — `llm_call` over `$pages[]` → `$summary`
4. **Store** — `memory_write(path: knowledge/research/$topic.md, content: $summary)`

## Notes
- Total cost: ~4-6 tool calls per run
- Typical duration: 30-60 seconds
```

Compositions are:
- **Human-editable** — open in Obsidian, adjust the workflow
- **Inspectable** — you can read exactly what a "research" command will do
- **Versionable** — git tracks changes to workflows
- **Composable** — compositions can reference other compositions

## Tool Discovery and Installation

```bash
# Install from local path (Ring 1 — you trust it)
kyber tool install ./my_tool --trust verified

# Install from MCP server (Ring 2)
kyber tool install mcp://github.com/some/mcp-server

# List installed tools with trust levels
kyber tool list

# Promote after audit
kyber tool trust web_search verified

# View tool knowledge
kyber tool info web_search  # opens knowledge/tools/web_search.md
```

## Implementation Phases

### Phase 1 (Current): Hardcoded Builtins + Manual Tools
- Ring 0 tools built into core (memory, vault, delta)
- Ring 1 tools as plugins (LLM, TTS, Discord)
- Tool definitions registered in `Kyber.Tools`
- `Kyber.ToolExecutor` dispatches based on tool name
- No composition engine yet
- Knowledge notes created manually

### Phase 2: Knowledge + Adapters
- Tool knowledge notes auto-created on install
- Usage tracking (counts, failure rates, last_used) via delta aggregation
- Quirks accumulation via extraction pipeline
- MCP adapter for ecosystem access (if needed)

### Phase 3: Composition + Discovery
- Composition engine (vault-note-defined workflows)
- Capability enforcement (Ring 2-3 sandboxing via BEAM process isolation)
- Auto-promotion tracking based on usage + audit history

### Phase 4: Learning Tools
- Extraction pipeline captures tool insights from conversations
- Failure pattern detection and automatic quirk logging
- Tool recommendation ("you usually use X for this kind of task")

## What We're NOT Doing

- **No implicit trust escalation.** Ring 2 tools don't magically become Ring 1 through usage. Promotion requires explicit human action.
- **No tool-specific APIs.** Tools use the same plugin interface as everything else.
- **No runtime tool generation.** The agent doesn't write new tools on the fly. Tools are code, reviewed by humans.

## Connection to Other Design Docs

- **Principles** (design-principles.md): Implements Principle 7 (Plugins All the Way Down) and Principle 6 (The Agent Maintains Itself — via tool knowledge notes).
- **Secrets** (secrets-and-trust.md): Tools declare secret requirements in manifests using the `{plugin}.{service}.{key}` namespace convention. Effect executor resolves at call time.
- **Memory** (memory-architecture.md): Tool knowledge notes live in the vault as `knowledge/tools/*.md`. Extraction pipeline maintains them.
- **Observability** (observability.md): Every tool execution produces a `tool.result` delta with DeltaMeta (duration_ms, cost, errors). Tool failure patterns tracked in knowledge notes.

---

*A tool that doesn't teach you anything is just a function. A tool that accumulates wisdom is a craft.*
