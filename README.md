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

## Quick Start

### One-line setup (macOS)

```bash
./scripts/setup.sh
```

This installs Homebrew, Erlang, Elixir, Node.js, and all dependencies. On other OSes, follow the manual steps printed by the script.

### Import from OpenClaw

If you have an OpenClaw vault export (zip with SOUL.md, MEMORY.md, etc.):

```bash
./scripts/setup.sh --import-openclaw /path/to/openclaw-export.zip
# or after setup:
mix kyber.import.openclaw /path/to/openclaw-export.zip
```

### Import from existing Kyber vault

```bash
./scripts/setup.sh --import-kyber /path/to/kyber-vault.zip
# or after setup:
mix kyber.import.kyber /path/to/kyber-vault.zip
```

### Configure and run

```bash
cp .env.example .env        # add DISCORD_BOT_TOKEN
mix run --no-halt            # or: ./scripts/start.sh
```

Dashboard: http://localhost:4001

### LLM Backend

Kyber-BEAM supports two LLM backends:

- **`:api`** (default) — Direct Anthropic Messages API. Uses OAuth token from `~/.openclaw/` or an API key.
- **`:agent_sdk`** — Claude Agent SDK via a Node.js bridge process. Authenticates using Claude CLI credentials from `~/.claude/`.

Switch backends by setting `KYBER_LLM_BACKEND=agent_sdk` in your `.env` file, or in config:

```elixir
config :kyber_beam, :llm_backend, :agent_sdk
```

The Agent SDK bridge requires Node.js 18+ and `npm install` in `priv/agent-sdk/`. The setup script handles this automatically. If the Agent SDK is unavailable at runtime, kyber-beam falls back to the direct API.

### Configuration

```elixir
config :kyber_beam, :model, "claude-sonnet-4-20250514"
config :kyber_beam, :vault_path, Path.expand("~/.kyber/vault")
```

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
