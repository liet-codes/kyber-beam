# KyberBeam

An **event-sourcing agent framework** built on BEAM/Elixir/OTP. Kyber-Beam powers sophisticated AI agents with immutable delta logs, hierarchical memory (L0/L1/L2 context), tool sandboxing, and real-time observability.

Designed for developers who want the reliability of actor-model concurrency with the flexibility of agent-driven workflows.

## Features

- **Immutable event log** — All agent state changes replayed from deltas. Audit trail for free.
- **Hierarchical memory** — L0 (tags) → L1 (summary) → L2 (full context). Automatic L0/L1 generation from full text.
- **Tool system** — Sandboxed exec allowlist, web fetch, plugin architecture. Extendable via Plugins.
- **BEAM introspection** — 16 built-in tools for process inspection, memory profiling, supervision tree status.
- **Cron scheduling** — Recurring tasks, one-shot reminders, proper timezone handling. Persistent across restarts.
- **Plugin architecture** — LLM (Claude), Discord, Knowledge vault, extensible via `Plugin.Manager`.
- **Real-time observability** — Delta stream, system health metrics, LiveView dashboard (optional).
- **Security hardened** — BearerAuth, exec injection guards, ephemeral field filtering, RLS integration.

## Quick Start

### Prerequisites

- Elixir 1.14+
- OTP 25+

### Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:kyber_beam, git: "https://github.com/liet-codes/kyber-beam"}
  ]
end
```

### Basic Setup

Create a minimal supervisor:

```elixir
defmodule MyAgent.Application do
  use Application

  def start(_type, _args) do
    children = [
      Kyber.Core,
      {Kyber.Plugin.LLM, [token: System.get_env("ANTHROPIC_API_KEY")]},
      {Kyber.Plugin.Discord, [token: System.get_env("DISCORD_BOT_TOKEN"), handler_pid: self()]}
    ]

    opts = [strategy: :one_for_one, name: MyAgent.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

### Running the Test Suite

```bash
mix test
```

All tests run in isolation using BEAM process isolation. No external services required for unit tests.

## Architecture

### Delta-Based State Machine

Kyber-Beam works by emitting immutable **deltas** — change records with type, payload, and origin.

```elixir
delta = Kyber.Delta.new("agent.thinking", %{"about" => "breakfast"}, {:llm, "claude"})
Kyber.Core.emit(delta)
```

The reducer processes deltas sequentially, updating state. State is never mutated; instead, new state is computed from the previous state + delta. This makes the entire history reproducible.

### Plugins

Plugins are GenServers that listen for deltas and emit effects:

```elixir
defmodule MyPlugin do
  use GenServer

  def handle_info({:delta, delta}, state) do
    case delta.type do
      "user.message" -> 
        # react to user input
        {:noreply, state}
      _ -> 
        {:noreply, state}
    end
  end
end
```

Built-in plugins:
- **LLM** — Calls Claude via Anthropic API, handles streaming.
- **Discord** — WebSocket gateway, message relay, presence updates.
- **Knowledge** — Obsidian vault integration, markdown parsing, L0/L1/L2 context.
- **Cron** — Scheduling system with persistent job storage.

### Memory Model

Each agent maintains a **memory vault** with three levels:

1. **L0** — Tags + summary (what is this about?)
2. **L1** — First paragraph or bullet points (quick ref)
3. **L2** — Full text (for detailed recall)

L0/L1 are auto-generated from L2 via the LLM plugin. This keeps context windows tight while retaining full history.

## Observability

### LiveView Dashboard

Start the web server:

```bash
iex -S mix phx.server
```

Visit `http://localhost:4000` to see:
- **Deltas stream** — Real-time state changes
- **Process tree** — Supervision tree status
- **Memory usage** — Heap size, ETS tables, message queues
- **Tool status** — LLM tokens used, Discord connection state

### Logs

Kyber-Beam uses OTP Logger. Configure verbosity in `config/config.exs`:

```elixir
config :logger, level: :info
```

## Development

### Running Tests Locally

```bash
# All tests
mix test

# Specific module
mix test test/kyber_beam/core_test.exs

# With coverage
mix test --cover
```

### Building Docs

```bash
mix docs
open doc/index.html
```

## Design Principles

1. **Immutability first** — State is never mutated; new state is always computed from previous state + delta.
2. **Observability built-in** — Every state change emits a delta that can be logged, replayed, or streamed to external systems.
3. **Fail-safe defaults** — Unknown deltas are safely ignored. Unknown plugins degrade gracefully.
4. **Explicit security** — No implicit trust. Tools are sandboxed, APIs require auth, system keys are filtered.

## License

MIT. See LICENSE file.

## Contributing

Issues and PRs welcome. Keep commits focused and tests green.
