# Kyber-BEAM

A custom LLM agent harness built in Elixir/OTP. Sovereign alternative to black-box agent frameworks.

Kyber-BEAM uses a **unidirectional dataflow architecture**: every state change flows through an append-only delta log, a pure reducer, and an effect system. Built to run Liet — an AI agent with an Obsidian-native knowledge layer, Discord integration, and full tool access.

## Key Features

- **Append-only delta log** — source of truth; replay any delta sequence to reconstruct state
- **Pure reducer** — `(state, delta) → {new_state, effects}` — deterministic, testable
- **Plugin system** — hot-reloadable GenServer plugins (LLM, Discord, Knowledge, Cron, Voice)
- **Obsidian vault knowledge layer** — salience-based memory with L0/L1/L2 tiered context
- **Discord integration** — gateway, messaging, reactions, thread support
- **Cron scheduling** — recurring tasks and one-shot reminders, persistent across restarts
- **Tool execution** — exec (allowlist-sandboxed), web_fetch, camera snap, file ops, BEAM introspection
- **OAuth token support** — works with Anthropic Max plan OAuth tokens (not just API keys)
- **LiveView dashboard** — real-time delta stream and process tree *(in progress)*

## Installation

### Fresh Mac (zero to running)

```bash
git clone https://github.com/liet-codes/kyber-beam.git
cd kyber-beam
./scripts/setup.sh
```

This installs Homebrew, asdf, Erlang, Elixir, Node.js, and all dependencies. On other OSes, follow the manual steps printed by the script.

### Importing an agent

Kyber-BEAM uses essence zips — portable bundles containing an agent's identity, memories, and knowledge.

**Import during setup:**
```bash
# Import an OpenClaw agent (e.g. Liet)
./scripts/setup.sh --import-openclaw /path/to/liet-essence.zip

# Import an existing Kyber agent (e.g. Stilgar)
./scripts/setup.sh --import-kyber /path/to/stilgar-essence.zip
```

**Import after setup:**
```bash
mix kyber.import.openclaw /path/to/liet-essence.zip --agent-name liet
mix kyber.import.kyber /path/to/stilgar-essence.zip --agent-name stilgar
```

### Configure

```bash
cp .env.example .env
```

Edit `.env` with your tokens:
```bash
DISCORD_BOT_TOKEN=your_discord_bot_token
# Optional: ANTHROPIC_API_KEY=sk-ant-api03-...
# Optional: KYBER_LLM_BACKEND=agent_sdk
```

Or in `config/runtime.exs`:
```elixir
config :kyber_beam,
  model: "claude-sonnet-4-20250514",
  agent_name: "stilgar",
  vault_path: Path.expand("~/.kyber/vault")
```

### Run

```bash
mix run --no-halt
```

Dashboard: http://localhost:4000 | API: http://localhost:4001

### Run as a background service (macOS)

```bash
cp com.liet.kyber-beam.plist ~/Library/LaunchAgents/
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.liet.kyber-beam.plist
```

Logs: `~/.kyber/logs/kyber-beam.log`

## Multi-Agent Vault

Kyber-BEAM supports multiple agents sharing a single vault. Each agent has its own identity and memory, while knowledge (concepts, people, projects) is shared.

```
~/.kyber/vault/
  shared/                    # All agents read/write
    concepts/                # Groovy commutator, wet math, etc.
    people/                  # Contacts and relationships
    projects/                # Project tracking
    USER.md                  # Same human for all agents
  agents/
    stilgar/                 # Agent-specific
      SOUL.md                # Identity and personality
      MEMORY.md              # Curated long-term memory
      TOOLS.md               # Environment notes
      AGENTS.md              # Workspace conventions
      memory/                # Daily notes (YYYY-MM-DD.md)
    liet/                    # Another agent
      SOUL.md
      MEMORY.md
      ...
```

Set which agent to run via config:
```elixir
config :kyber_beam, :agent_name, "stilgar"
```

The Knowledge module auto-detects the vault layout. Agent-specific paths (`SOUL.md`, `memory/2026-04-04.md`) resolve to `agents/<name>/...` automatically. Shared paths (`concepts/foo.md`) resolve to `shared/...`.

## LLM Backend

Two backends available:

- **`:api`** (default) — Direct Anthropic Messages API. Uses OAuth token from `~/.openclaw/` or an API key.
- **`:agent_sdk`** — Claude Agent SDK via a Node.js bridge. Authenticates using Claude CLI credentials from `~/.claude/`.

Switch backends:
```bash
# In .env
KYBER_LLM_BACKEND=agent_sdk

# Or in config
config :kyber_beam, :llm_backend, :agent_sdk
```

The Agent SDK bridge requires Node.js 18+ and runs `npm install` in `priv/agent-sdk/` automatically during setup. If the Agent SDK is unavailable at runtime, kyber-beam falls back to the direct API.

## Architecture

```
Discord / HTTP / Cron
        │
        ▼
   Delta (type + payload + origin)
        │
        ▼
   Kyber.Core  ──►  Reducer  ──►  new state
        │
        ▼
   Effect.Executor
        │
   ┌────┴────────────────┐
   ▼                     ▼
LLM Plugin          Discord Plugin
(Anthropic API)     (send/react/thread)
   │
   ▼
Tool Loop (exec, web_fetch, memory_read, ...)
   │
   ▼
Delta("llm.response") → back into Core
```

**Delta** — immutable record: `{id, type, payload, origin, parent_id, timestamp}`

**Reducer** — pure function matching on `delta.type`. No side effects; returns `{state, effects}`.

**Effect Executor** — dispatches effects to registered plugin handlers. Plugins register handlers at startup and re-register if the executor restarts.

**Session** — per-channel conversation history. Capped at 20 messages. Stored as deltas.

**Knowledge** — Obsidian vault with tiered retrieval (L0 tags, L1 summary, L2 full body). Salience scoring drives what stays in working memory.

## Project Layout

```
lib/kyber_beam/
  core.ex             # Delta log + reducer loop
  delta.ex            # Delta struct
  reducer.ex          # Pure reducer (pattern match on delta.type)
  effect/             # Effect.Executor + handler registry
  plugin/             # LLM, Discord, Voice, Cron plugins
  memory/             # Consolidator + salience model
  knowledge.ex        # Obsidian vault GenServer
  session.ex          # Per-channel conversation history
  tools/              # Tool definitions + executor
  web/                # LiveView dashboard (Phoenix)
```

## Status

Active development. P0–P2 burndown complete (core loop, auth, Discord, tools, memory, cron).  
See [BURNDOWN.md](BURNDOWN.md) for remaining P3 items.

## License

MIT. See [LICENSE](LICENSE).
