# Operating Procedures for Kyber-BEAM (Hermes Edition)

*Living document. Dictates how Hermes/Veles (and Claude Code subagents) interact with this repository.*

## 1. The Source of Truth
- `PLAN.md` is the absolute source of truth for the project. Every Pull Request or major feature commit **MUST** update `PLAN.md` to reflect the new state of the repository.
- There are no auxiliary tracking files. All architecture notes, audits, and checklists live in or are referenced by `PLAN.md`.

## 2. Testing Philosophy (Simulation)
- Because running a full local AI pipeline (Qwen) and mounting a live Obsidian vault is heavy, all core logic is tested via **Elixir ExUnit Integration and Unit Tests**.
- The system is built on pure reducers: `(state, delta) → {new_state, effects}`. You do not need the network or the LLM to test the reducer.
- If you write a new feature, you must write the test that simulates the Delta, runs it through the Reducer, and asserts on the resulting Effect.

## 3. Test-Driven Development (TDD)
- **Workflow:** Red → Green → Refactor.
- Write the failing ExUnit test first. Run `mix test` and verify that exactly the thing you intended to fail fails.
- Write the minimal code to make it pass.
- Run `mix test` to confirm everything else is still green.

## 4. Elixir/OTP Constraints
- Follow standard Elixir idioms: `defmodule`, `@spec`, `defstruct`. Focus on immutability.
- If creating a stateful process, use a `GenServer` supervised by the application, with a clear restart strategy.
- Do not perform blocking I/O (like reading the Obsidian vault) directly in a `GenServer` handle_call if it will exceed a few milliseconds. Dispatch to a `Task` or use `{:noreply, state}` with `spawn_monitor`.

## 5. Architectural Non-Negotiables
- **Append-only Delta Log:** Be extremely careful when touching `kyber_beam/delta/`. This is the core cognitive record. Never mutate an existing delta.
- **Human-navigable Vault:** Memory isn't a database schema; it's a markdown file that a human can read and edit in Obsidian.

## 6. Code Generation Delegation (Claude Code)
Hermes will actively use Claude Code as a high-powered coding sub-agent.
* Execute Claude Code in non-interactive print mode for fast, bounded tasks:
  `claude -p 'Build the delegate_task feature and update the tests' --max-turns 15 --allowedTools 'Read,Edit,Bash'`
* Hermes acts as the DevOps architect, defining the specs, running the tests, and updating `PLAN.md`, delegating raw code generation directly to Claude.