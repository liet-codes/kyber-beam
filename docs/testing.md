# Testing & Statelessness

*Design doc — ported from TypeScript kyber repo (2026-03-16). Adapted for Elixir/ExUnit.*

Two hard rules. No exceptions.

## Rule 1: All Server Logic is Stateless

The server holds **zero meaningful state in memory**. All state lives in:
- **Delta log** (append-only JSONL on disk via `Kyber.Delta.Store`)
- **Vault** (Obsidian markdown files on disk via `Kyber.Knowledge`)
- **ETS tables** (derived caches, always reconstructible from disk)

This means:
- Process restart loses nothing — state is on disk
- Hot reload is safe — ETS is rebuilt from delta log or vault
- Testing is straightforward — fixtures on disk, no mock for internal state

### What "stateless" means in practice

```elixir
# ❌ BAD — meaningful state in process memory
defmodule Kyber.Plugin.Discord do
  use GenServer

  def init([]) do
    {:ok, %{message_count: 0, last_sender: nil}}  # dies on restart
  end

  def handle_cast({:message, msg}, state) do
    {:noreply, %{state | message_count: state.message_count + 1}}
  end
end

# ✅ GOOD — state in deltas
defmodule Kyber.Plugin.Discord do
  use GenServer

  def handle_cast({:message, msg}, state) do
    Kyber.Delta.Store.append(%Delta{
      kind: "message.received",
      payload: %{text: msg.content, sender: msg.author.id}
    })
    # If we need message count, query the delta log
    {:noreply, state}
  end
end
```

### Allowed in-memory: caches and connections only

Some things live in memory because they're ephemeral by nature:
- Discord WebSocket connection (re-established on restart)
- ETS caches with reconstructible content (Delta.Store subscriptions, Knowledge L0 index)
- Route handler registrations (rebuilt on reload)
- Task.Supervisor task references

The test: **if the process dies and restarts, does anything get permanently lost?** If yes, it shouldn't be in memory — it should be in the delta log or vault.

### The reducer is a pure function

```elixir
# reducer.ex
defmodule Kyber.Reducer do
  @spec reduce(State.t(), Delta.t()) :: {State.t(), [Effect.t()]}
  def reduce(state, delta) do
    # NO side effects. NO I/O. NO process calls.
    # Just: state + delta → new state + list of effects to execute
    case delta.kind do
      "message.received" ->
        {
          %{state | last_message: delta.payload},
          [{:llm_call, messages: build_context(state, delta)}]
        }

      "plugin.loaded" ->
        {
          %{state | plugins: [delta.payload.name | state.plugins]},
          []
        }

      _ ->
        {state, []}
    end
  end
end
```

The reducer takes data in and returns data out. It doesn't touch the filesystem, the network, or any process. Effects are descriptions of what *should* happen — `Kyber.Effect.Executor` handles the actual I/O.

This makes the entire decision-making core unit-testable without any infrastructure.

## Rule 2: TDD Everything

Red → Green → Refactor. No code lands without tests that existed first.

### Test Structure

```
test/
├── kyber_beam/
│   ├── reducer_test.exs          # Pure function — fast, no I/O
│   ├── delta_test.exs
│   ├── state_test.exs
│   ├── delta/
│   │   └── store_test.exs
│   ├── plugin/
│   │   ├── discord_test.exs
│   │   ├── llm_test.exs
│   │   └── ...
│   └── ...
│
├── support/
│   ├── test_helpers.ex           # Shared helpers
│   ├── delta_builder.ex          # Fluent builder for test deltas
│   ├── mock_discord.ex           # Fake Discord adapter
│   └── fixtures/
│       ├── deltas/               # Sample delta sequences (JSONL)
│       │   ├── simple_message.jsonl
│       │   ├── multi_turn.jsonl
│       │   └── error_recovery.jsonl
│       └── vault/                # Minimal vault snapshots
│           ├── empty/
│           ├── with_identity/    # Has SOUL.md + USER.md
│           └── full/
│
└── test_helper.exs
```

### Testing Pyramid

```
                    ┌─────────┐
                    │   E2E   │  Few: full app + real Discord (staging bot)
                    ├─────────┤
                 ┌──┤ Integr. ├──┐  Some: plugin + core + temp vault
                 │  ├─────────┤  │
              ┌──┤  │  Unit   │  ├──┐  Many: pure functions, no I/O
              │  │  └─────────┘  │  │
              └──┘               └──┘
```

**Unit tests** (the bulk):
- Reducer: given state + delta → expect new state + effects
- Delta building: given input → expect well-formed delta
- Effect descriptions: given state change → expect correct effect list
- Vault queries: given fixture vault → expect correct results

**Integration tests:**
- Plugin startup + delta emission through the full pipeline
- Effect execution writing to a temp vault
- Hot reload cycle (load → use → reload → use)
- Health check + snapshot creation
- Session rehydration from delta log

**E2E tests (few):**
- Full app boot → receive Discord message → respond
- Update pipeline: tag → apply → restart → verify
- Watchdog revert scenario (intentionally break, verify recovery)

### Test Helpers

```elixir
# test/support/test_helpers.ex
defmodule Kyber.TestHelpers do
  @doc """
  Spin up an isolated Kyber instance with temp dirs.
  Automatically cleans up after the test.
  """
  def create_test_kyber(opts \\ []) do
    tmp_dir = Path.join(System.tmp_dir!(), "kyber-test-#{:rand.uniform(999_999)}")
    vault_dir = Path.join(tmp_dir, "vault")
    delta_dir = Path.join(tmp_dir, "deltas")

    File.mkdir_p!(vault_dir)
    File.mkdir_p!(delta_dir)

    # Copy fixtures if provided
    if fixture = opts[:fixtures] do
      fixture_path = Path.join([__DIR__, "fixtures", "vault", to_string(fixture)])
      File.cp_r!(fixture_path, vault_dir)
    end

    # Start isolated supervised processes for this test
    {:ok, _} = start_supervised({Kyber.Delta.Store, [store_path: delta_dir]})
    {:ok, _} = start_supervised({Kyber.Knowledge, [vault_path: vault_dir]})

    %{
      tmp_dir: tmp_dir,
      vault_dir: vault_dir,
      delta_dir: delta_dir
    }
  end
end
```

```elixir
# test/support/delta_builder.ex
defmodule Kyber.DeltaBuilder do
  @doc "Fluent builder for test deltas"
  def build(kind, opts \\ []) do
    %Kyber.Delta{
      id: "test_#{System.unique_integer([:positive])}",
      ts: System.system_time(:millisecond),
      kind: kind,
      origin: opts[:origin] || %{type: "system", reason: "test"},
      payload: opts[:payload] || %{},
      parent_id: opts[:parent_id]
    }
  end
end
```

### Avoiding Process.sleep

Widespread `Process.sleep` for async coordination is a flakiness factory. Use these patterns instead:

```elixir
# ❌ Fragile — timing-dependent
assert send_delta(delta) == :ok
Process.sleep(100)
assert get_state().last_message == expected

# ✅ Reliable — subscribe before acting, then wait for the specific event
Kyber.Delta.Store.subscribe()
send_delta(delta)
assert_receive {:delta, %Delta{kind: "llm.response"}}, 2_000

# ✅ Also good — assert_eventually for polling with backoff
defp assert_eventually(fun, timeout \\ 1_000) do
  deadline = System.monotonic_time(:millisecond) + timeout
  do_assert_eventually(fun, deadline)
end
```

### Example: TDD the Reducer

```elixir
# test/kyber_beam/reducer_test.exs
defmodule Kyber.ReducerTest do
  use ExUnit.Case, async: true

  import Kyber.DeltaBuilder

  describe "message.received" do
    test "creates an llm_call effect" do
      state = Kyber.State.empty()
      delta = build("message.received",
        origin: %{type: "channel", channel: "discord:dm", chat_id: "123", sender_id: "456"},
        payload: %{text: "hello", sender: "myk"}
      )

      {_new_state, effects} = Kyber.Reducer.reduce(state, delta)

      assert length(effects) == 1
      assert {:llm_call, messages: _} = hd(effects)
    end
  end

  describe "error.route" do
    test "emits no effects, just state update" do
      state = Kyber.State.empty()
      delta = build("error.route", payload: %{path: "/api/foo", error: "boom"})

      {new_state, effects} = Kyber.Reducer.reduce(state, delta)

      assert effects == []
      assert length(new_state.errors) == 1
    end
  end

  describe "plugin.loaded" do
    test "updates loaded plugins list" do
      state = Kyber.State.empty()
      delta = build("plugin.loaded", payload: %{name: "discord"})

      {new_state, _effects} = Kyber.Reducer.reduce(state, delta)

      assert "discord" in new_state.plugins
    end
  end
end
```

### Example: TDD a Plugin

```elixir
# test/kyber_beam/plugin/discord_test.exs
defmodule Kyber.Plugin.DiscordTest do
  use ExUnit.Case

  import Kyber.TestHelpers
  import Kyber.DeltaBuilder

  setup do
    create_test_kyber(fixtures: :with_identity)
  end

  # RED first — write the test, then implement
  test "emits message.received delta on incoming message" do
    Kyber.Delta.Store.subscribe()

    Kyber.Plugin.Discord.Mock.simulate_message(%{
      content: "hello",
      author: %{id: "123", username: "myk"},
      channel_id: "456"
    })

    assert_receive {:delta, %Kyber.Delta{kind: "message.received"} = delta}, 2_000
    assert delta.payload.text == "hello"
    assert delta.origin.channel == "discord"
  end
end
```

### CI Configuration

```yaml
# .github/workflows/test.yml (if/when CI is set up)
name: Test
on: [push, pull_request]
jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: erlef/setup-beam@v1
        with:
          elixir-version: '1.17'
          otp-version: '27'
      - run: mix deps.get
      - run: mix compile --warnings-as-errors
      - run: mix test
      - run: mix credo --strict
      - run: mix dialyzer  # type checking
```

### What Doesn't Get Merged Without

- [ ] Tests exist and pass
- [ ] Tests were written before the implementation (TDD, not retroactive)
- [ ] No meaningful in-memory state (or documented exception with justification)
- [ ] Reducer changes have unit tests for every new delta kind
- [ ] Plugin changes have integration tests
- [ ] No `Process.sleep` in tests without a comment explaining why it's necessary
- [ ] 0 compiler warnings (`--warnings-as-errors` in CI)
- [ ] No Credo violations (`mix credo --strict`)

## The Reducer Is the Heart

The whole architecture bets on this: **if the reducer is correct and pure, the system is correct**. All state transitions happen through the reducer. All effects are descriptions. All persistence is in the delta log.

This means:
- You can replay any sequence of deltas against the reducer and get deterministic output
- You can unit test every state transition without network, disk, or process infrastructure
- You can debug any bug by finding the delta that caused it
- You can add observability by looking at what the reducer emits, not by adding logging everywhere

Keep the reducer pure. Keep it tested. Everything else follows.
