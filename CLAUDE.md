     1|     1|# Operating Procedures for Kyber-BEAM (Hermes Edition)
     2|     2|
     3|     3|*Living document. Dictates how Hermes/Veles (and Claude Code subagents) interact with this repository.*
     4|     4|
     5|     5|## 1. The Source of Truth
     6|     6|- `PLAN.md` is the absolute source of truth for the project. Every Pull Request or major feature commit **MUST** update `PLAN.md` to reflect the new state of the repository.
     7|     7|- There are no auxiliary tracking files. All architecture notes, audits, and checklists live in or are referenced by `PLAN.md`.
     8|     8|
     9|     9|## 2. Testing Philosophy & Quality Mandates
- All core logic is tested via **Elixir ExUnit Integration and Unit Tests**.
- **Test Fragility Mandate:** Do not use `Process.sleep/1` to wait for asynchronous GenServer state changes. It creates flaky tests. You must use `assert_receive/3`, `catch_exit`, or explicit state polling.
- The system is built on pure reducers: `(state, delta) -> {new_state, effects}`. Verify the effects emitted, not just the state changed.

## 3. Test-Driven Development (TDD)
    15|    15|- **Workflow:** Red → Green → Refactor.
    16|    16|- Write the failing ExUnit test first. Run `mix test` and verify that exactly the thing you intended to fail fails.
    17|    17|- Write the minimal code to make it pass.
    18|    18|- Run `mix test` to confirm everything else is still green.
    19|    19|
    20|    20|## 4. Elixir/OTP Constraints
    21|    21|- Follow standard Elixir idioms: `defmodule`, `@spec`, `defstruct`. Focus on immutability.
    22|    22|- If creating a stateful process, use a `GenServer` supervised by the application, with a clear restart strategy.
    23|    23|- Do not perform blocking I/O (like reading the Obsidian vault) directly in a `GenServer` handle_call if it will exceed a few milliseconds. Dispatch to a `Task` or use `{:noreply, state}` with `spawn_monitor`.
    24|    24|
    25|    25|## 5. Architectural Non-Negotiables
    26|    26|- **Append-only Delta Log:** Be extremely careful when touching `kyber_beam/delta/`. This is the core cognitive record. Never mutate an existing delta.
    27|    27|- **Human-navigable Vault:** Memory isn't a database schema; it's a markdown file that a human can read and edit in Obsidian.
    28|    28|
    29|    29|## 6. Code Generation Delegation (Claude Code)
    30|    30|Hermes will actively use Claude Code as a high-powered coding sub-agent.
    31|    31|* Execute Claude Code in non-interactive print mode for fast, bounded tasks:
    32|    32|  `claude -p 'Build the delegate_task feature and update the tests' --max-turns 15 --allowedTools 'Read,Edit,Bash'`
    33|    33|* Hermes acts as the DevOps architect, defining the specs, running the tests, and updating `PLAN.md`, delegating raw code generation directly to Claude.
    34|
    35|## 7. The Ralph Loop (Autonomous Execution)
We operate on a "Ralph Loop" by default for feature engineering:
1. **Define:** The top of `PLAN.md` (Section 0) strictly defines the Requirements and Success Criteria for the *next* loop.
2. **Execute:** Claude Code (`claude -p`) is launched to write the code and the tests.
3. **Verify (The Review Gate):** **Hermes** acts as the Review Gate. Hermes must execute the ExUnit tests, verify that no `Process.sleep` fragility was introduced, and confirm the architecture aligns with `AUDIT-HISTORY.md`.
4. **Update:** **Hermes** strictly owns updating `PLAN.md` to clear the loop and define the next objective. Claude Code does not overwrite the plan.

Claude Code: Achieve the Success Criteria, ensure tests pass, and stop. Hermes will verify and integrate.
