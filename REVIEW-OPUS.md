# Kyber BEAM — Code Review

**Reviewer:** Liet (Staff Engineer review)
**Date:** 2026-03-18
**Scope:** All source files in `lib/`
**Test status:** 160 tests, 1 failure (`Kyber.CoreTest` — `emit error.route updates state.errors`), 3 compiler warnings

---

## Summary

Kyber BEAM is an early-stage agent harness with a clean delta-driven unidirectional dataflow architecture. The core concepts — immutable deltas, pure reducer, effect system — are sound and well-separated. The supervision tree is reasonable for the current stage. However, there are several concurrency issues, an architectural concern with the pipeline wiring, and some OTP anti-patterns that should be addressed before this goes further.

**Counts:** 4 Critical, 6 High, 7 Medium, 5 Low

---

## 1. CRITICAL — Must Fix

### C1. Unsupervised Task wires the entire pipeline — crash = silent death

**File:** `lib/kyber_beam/core.ex:118-122`

```elixir
Task.start(fn ->
  Process.sleep(50)
  subscribe_reducer(core_name, store, state, executor)
  Logger.info("[Kyber.Core] pipeline wired for #{inspect(core_name)}")
end)
```

**What's wrong:** `Task.start/1` creates a fire-and-forget, **unsupervised** task. If this task crashes (e.g., the Store isn't ready in 50ms, which the test output confirms happens), the pipeline is never wired and the system silently does nothing. No deltas will flow to the reducer. No effects will fire. The system looks alive but is brain-dead.

This is the root cause of the failing test — the `Process.sleep(50)` is a race condition. Under test load, child processes sometimes aren't registered by 50ms.

**Why it matters:** This is the single most important operation in the entire system. If it fails, nothing works.

**Suggested fix:** Use `handle_continue/2` or a supervised init task with retries:

```elixir
@impl true
def init(opts) do
  core_name = Keyword.get(opts, :name, __MODULE__)
  store_path = Keyword.get(opts, :store_path, default_store_path())

  # ... children setup ...

  {:ok, Supervisor.init(children, strategy: :one_for_one),
   {:continue, {core_name, store_name(core_name), state_name(core_name), executor_name(core_name)}}}
end

# Note: Supervisor doesn't support handle_continue.
# Better approach: use a dedicated "wiring" GenServer as the last child:
```

Since `Supervisor` doesn't support `handle_continue`, the proper fix is to add a dedicated wiring GenServer as the last child in the supervision tree:

```elixir
children = [
  {Task.Supervisor, name: task_sup},
  {Kyber.Delta.Store, [name: store, path: store_path]},
  {Kyber.State, [name: state]},
  {Kyber.Effect.Executor, [name: executor, task_supervisor: task_sup]},
  {Kyber.Plugin.Manager, [name: plugin_mgr]},
  {Kyber.Core.Wiring, [core: core_name, store: store, state: state, executor: executor]}
]
```

The `Wiring` GenServer subscribes in `init/1` — at that point all prior children are guaranteed started (since `one_for_one` starts sequentially). If it crashes, the supervisor restarts it and it re-subscribes.

### C2. Subscriber callbacks run in unmonitored `Task.start` — silent failures

**File:** `lib/kyber_beam/delta/store.ex:96-99`

```elixir
defp broadcast(%{subs: subs}, delta) do
  Enum.each(subs, fn {_id, callback_fn} ->
    Task.start(fn -> callback_fn.(delta) end)
  end)
end
```

**What's wrong:** `Task.start/1` creates unsupervised, unlinked tasks. If a subscriber callback crashes:
1. Nobody knows
2. The delta is lost for that subscriber
3. In the pipeline case (C1), this means a delta silently fails to reach the reducer

Since the subscription callback IS the pipeline (store → reducer → state → effects), a crash here means deltas are silently dropped.

**Why it matters:** The entire dataflow depends on this. Silent failures = invisible data loss.

**Suggested fix:** Use `Task.Supervisor.start_child` with the Core's TaskSupervisor, or at minimum `Task.start_link` with proper error handling. Better yet, for the critical pipeline callback, run it synchronously (it's already fast — reducer is pure, state update is an Agent call):

```elixir
defp broadcast(%{subs: subs}, delta) do
  Enum.each(subs, fn {_id, callback_fn} ->
    try do
      callback_fn.(delta)
    rescue
      e ->
        Logger.error("[Kyber.Delta.Store] subscriber callback crashed: #{inspect(e)}")
    end
  end)
end
```

If you want async, pass the TaskSupervisor reference and use `Task.Supervisor.start_child/2`.

### C3. `String.to_existing_atom` in Effect.Executor — atom table DoS / crash vector

**File:** `lib/kyber_beam/effect.ex:102`

```elixir
defp get_type(%{"type" => t}) when is_binary(t), do: String.to_existing_atom(t)
```

**What's wrong:** If the atom doesn't already exist, `String.to_existing_atom/1` raises `ArgumentError`. Since effects can arrive from external sources (HTTP API → delta → reducer → effect), an attacker or buggy client can crash the Executor by sending a novel effect type string. Additionally, if you used `String.to_atom/1` instead, it would be an atom table exhaustion vector.

**Why it matters:** Crash in the Executor means all effect dispatch stops until restart.

**Suggested fix:**

```elixir
defp get_type(%{"type" => t}) when is_binary(t) do
  try do
    String.to_existing_atom(t)
  rescue
    ArgumentError -> :unknown
  end
end
```

Or better: don't accept string-keyed effect maps in the internal pipeline. Effects from the reducer are already atom-keyed. Only accept `%Kyber.Effect{}` and atom-keyed maps:

```elixir
defp get_type(%Kyber.Effect{type: t}), do: t
defp get_type(%{type: t}) when is_atom(t), do: t
defp get_type(_), do: :unknown
```

### C4. WebSocket subscription callback sends to wrong process

**File:** `lib/kyber_beam/web/router.ex:93-97`

```elixir
def init(%{store: store}) do
  unsubscribe_fn = Kyber.Delta.Store.subscribe(store, fn delta ->
    send(self(), {:delta, delta})
  end)
  {:ok, %{unsubscribe_fn: unsubscribe_fn}}
end
```

**What's wrong:** The `fn delta -> send(self(), ...) end` closure captures `self()` at call time, not at definition time. Since subscribers are invoked via `Task.start` (see C2), `self()` inside the callback will be the **Task's PID**, not the WebSocket process. Deltas will be sent to ephemeral Task processes that immediately exit, never reaching the WebSocket.

**Why it matters:** WebSocket streaming is completely broken — no client will ever receive delta updates.

**Suggested fix:** Capture the WebSocket PID before creating the closure:

```elixir
def init(%{store: store}) do
  ws_pid = self()
  unsubscribe_fn = Kyber.Delta.Store.subscribe(store, fn delta ->
    send(ws_pid, {:delta, delta})
  end)
  {:ok, %{unsubscribe_fn: unsubscribe_fn}}
end
```

---

## 2. HIGH — Should Fix

### H1. `one_for_one` supervision in Core allows inconsistent state after crashes

**File:** `lib/kyber_beam/core.ex:113`

```elixir
Supervisor.init(children, strategy: :one_for_one)
```

**What's wrong:** With `one_for_one`, if `Kyber.Delta.Store` crashes and restarts, the subscription wiring (from C1) is lost. The new Store instance has no subscribers. The pipeline is broken until the entire Core supervisor is restarted. Similarly, if `Kyber.State` crashes, it restarts with empty state but the Store still has all deltas — state is now inconsistent.

**Why it matters:** After any child crash, the system enters an inconsistent state that requires manual intervention.

**Suggested fix:** Use `rest_for_one` — if the Store restarts, everything after it (State, Executor, PluginManager, and the Wiring GenServer from C1) restarts too, re-establishing the pipeline:

```elixir
Supervisor.init(children, strategy: :rest_for_one)
```

This naturally handles re-wiring after crashes. The State process could also replay deltas from the Store on startup to reconstruct state.

### H2. Delta list append is O(n) and grows unboundedly

**File:** `lib/kyber_beam/delta/store.ex:64`

```elixir
state = %{state | deltas: state.deltas ++ [delta]}
```

**What's wrong:** `list ++ [element]` is O(n) — it copies the entire list every time. At 10,000 deltas, every append copies 10,000 elements. At 100,000, it's unusable.

**Why it matters:** The Store is the hottest path in the system. Performance degrades linearly over time.

**Suggested fix:** Prepend and reverse on query, or use `:queue`, or move to ETS:

```elixir
# Option 1: Prepend (O(1) append, O(n) query — fine since queries are less frequent)
state = %{state | deltas: [delta | state.deltas]}

# Then in query, reverse first:
defp apply_limit(deltas, nil), do: Enum.reverse(deltas)
```

### H3. `errors ++ [error]` in State has the same O(n) problem with no bound

**File:** `lib/kyber_beam/state.ex:83`

```elixir
def add_error(%__MODULE__{} = state, error) when is_map(error) do
  %{state | errors: state.errors ++ [error]}
end
```

**What's wrong:** Same O(n) append issue as H2, plus errors accumulate forever with no cap.

**Suggested fix:** Prepend + cap at a reasonable limit:

```elixir
@max_errors 100

def add_error(%__MODULE__{} = state, error) when is_map(error) do
  errors = [error | state.errors] |> Enum.take(@max_errors)
  %{state | errors: errors}
end
```

### H4. `trap_exit` in Delta.Store and Session without handling EXIT messages

**File:** `lib/kyber_beam/delta/store.ex:58`, `lib/kyber_beam/session.ex:65`

**What's wrong:** Both `Delta.Store` and `Session` call `Process.flag(:trap_exit, true)` but neither has a `handle_info({:EXIT, ...}, state)` clause. The `handle_info` catch-all will log them as "unexpected message" warnings. More importantly, trapping exits in supervised GenServers is an anti-pattern unless you need to do cleanup — it changes how the supervisor interacts with the process (sends exit signals instead of killing).

**Why it matters:** Trapping exits without handling them properly can delay shutdown and cause supervision timeouts. The `terminate/2` callback is already called for normal shutdowns without trap_exit.

**Suggested fix:** Remove `Process.flag(:trap_exit, true)` from both. The `terminate/2` callbacks only do logging and ETS cleanup — ETS tables owned by the process are automatically cleaned up when the process dies. If you need the terminate callback for the file handle or other cleanup, keep trap_exit but add:

```elixir
def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}
```

### H5. ETS table is `:public` in Session — bypasses GenServer serialization

**File:** `lib/kyber_beam/session.ex:67`

```elixir
:ets.new(table, [:named_table, :public, :set, read_concurrency: true])
```

**What's wrong:** The table is `:public` and `get_history/2` reads directly from ETS without going through the GenServer. While reads are safe (ETS reads are atomic per-key), the design claim that "the GenServer serialises writes so there are no race conditions" is undermined — any process can write to the table since it's public.

**Why it matters:** A stray `:ets.insert` from anywhere would bypass the GenServer serialization, violating the module's stated invariant.

**Suggested fix:** Use `:protected` (default) — only the owning process can write:

```elixir
:ets.new(table, [:named_table, :protected, :set, read_concurrency: true])
```

### H6. No authentication on HTTP API

**File:** `lib/kyber_beam/web/router.ex`

**What's wrong:** The REST API (`POST /api/deltas`, `GET /api/deltas`, `GET /ws`) has no authentication. Anyone who can reach the port can emit arbitrary deltas into the system, read all deltas, or open a WebSocket.

**Why it matters:** Emitting arbitrary deltas can trigger LLM calls (billing), send Discord messages (impersonation), and inject data into the state. This is fine for local dev but should be flagged for any network-exposed deployment.

**Suggested fix:** Add a simple token-based plug for non-health endpoints:

```elixir
plug :authenticate, except: ["/health"]

defp authenticate(conn, _opts) do
  case get_req_header(conn, "authorization") do
    ["Bearer " <> token] when token == expected_token() -> conn
    _ -> conn |> send_resp(401, "unauthorized") |> halt()
  end
end
```

---

## 3. MEDIUM — Improve

### M1. `@registry` module attribute defined but never used

**File:** `lib/kyber_beam/delta/store.ex:16`

```elixir
@registry Kyber.Delta.Store.Registry
```

Compiler already warns about this. The moduledoc references "PubSub via Registry" but the implementation uses in-process subscriber maps. Remove the dead attribute.

### M2. `@gateway_url` module attribute defined but never used

**File:** `lib/kyber_beam/plugin/discord.ex:27`

Same — dead code. Gateway connection isn't implemented yet (the `:connect` handler is a stub). Clean up or mark with a `TODO`.

### M3. Confusing Gateway intents arithmetic in comments

**File:** `lib/kyber_beam/plugin/discord.ex:32-36`

```elixir
# Intents: GUILDS (1) | GUILD_MESSAGES (512) | MESSAGE_CONTENT (32768) = 33281
# Actually: GUILDS=1, GUILD_MESSAGES=512, MESSAGE_CONTENT=32768 → 1+512+32768 = 33281
# But the spec says 34307 which is GUILDS(1) + GUILD_MESSAGES(512) + MESSAGE_CONTENT(32768) + DIRECT_MESSAGES(4096) = 37377? 
# Let's use 34307 as specified
@gateway_intents 34307
```

The comment contradicts itself and the value. `34307` = `1 | 2 | 32 | 512 | 1024 | 32768` which includes GUILDS, GUILD_MEMBERS, GUILD_EXPRESSIONS, GUILD_MESSAGES, GUILD_MESSAGE_REACTIONS, and MESSAGE_CONTENT. Replace the comment with a clear bitwise expression:

```elixir
@gateway_intents Bitwise.bor(1, Bitwise.bor(512, 32768))  # GUILDS | GUILD_MESSAGES | MESSAGE_CONTENT
```

Or use the `use Bitwise` import and express it clearly.

### M4. Auth token extracted from filesystem with recursive search

**File:** `lib/kyber_beam/plugin/llm.ex:214-226`

```elixir
defp extract_token(data) when is_map(data) do
  Enum.find_value(data, fn {_k, v} ->
    case v do
      %{} -> extract_token(v)
      str when is_binary(str) and byte_size(str) > 20 ->
        if String.starts_with?(str, "sk-ant-"), do: str, else: nil
      _ -> nil
    end
  end)
end
```

**What's wrong:** Recursively searching any JSON structure for strings matching `"sk-ant-"` is fragile and could match unintended values. The explicit pattern matches above this clause are good — this fallback is risky.

**Suggested fix:** Remove the recursive fallback. If the auth file format changes, add an explicit pattern rather than guessing.

### M5. `handle_info/2` missing in Session GenServer

**File:** `lib/kyber_beam/session.ex`

The Session GenServer has no `handle_info/2` callback. Any unexpected messages (e.g., from trapping exits) will cause a crash with a `** no function clause matching` error since there's no catch-all.

**Suggested fix:**

```elixir
@impl true
def handle_info(msg, state) do
  Logger.warning("[Kyber.Session] unexpected message: #{inspect(msg)}")
  {:noreply, state}
end
```

### M6. `KyberBeam` root module is just a hello-world stub

**File:** `lib/kyber_beam.ex`

The root module only contains `hello/0` returning `:world`. This is the Mix generator default. Either make it a useful facade or remove it.

### M7. Bot token passed through closure — not refreshable

**File:** `lib/kyber_beam/plugin/discord.ex:131`

The Discord plugin captures the bot token in a closure during `init/1` and passes it to the effect handler. If the token needs rotation (unlikely for Discord, but good practice), the handler keeps using the stale token. Consider reading the token from state at call time.

---

## 4. LOW — Nice to Have

### L1. Deprecated `preferred_cli_env` in mix.exs

**File:** `mix.exs:10`

```elixir
preferred_cli_env: [coveralls: :test]
```

Move to `def cli`:

```elixir
def cli do
  [preferred_envs: [coveralls: :test]]
end
```

### L2. `use Plug.Test` deprecated warning in router tests

**File:** `test/kyber_beam/web/router_test.exs:3`

Replace with:
```elixir
import Plug.Test
import Plug.Conn
```

### L3. Multiple modules in single files

`lib/kyber_beam/delta.ex` defines both `Kyber.Delta` and `Kyber.Delta.Origin`. `lib/kyber_beam/effect.ex` defines both `Kyber.Effect` and `Kyber.Effect.Executor`. `lib/kyber_beam/web/router.ex` defines `Kyber.Web.Router`, `Kyber.Web.DeltaSocket`, and `Kyber.Web.Server`. Convention is one module per file. Split them when convenient.

### L4. No `@moduledoc` on `KyberBeam.Application`

Add documentation or at least `@moduledoc false` (already done — this is fine, noting for completeness).

### L5. `Process.sleep` in tests creates flaky timing

**File:** `test/kyber_beam/core_test.exs` — multiple instances

Every core test uses `Process.sleep(100)` or `Process.sleep(150)` to wait for the pipeline to wire up. This is the symptom of C1. Once the wiring is done synchronously via a supervised child, these sleeps can be removed and tests become deterministic.

---

## Test Coverage Analysis

**Covered well:**
- Delta creation, serialization, round-trip ✓
- Delta.Origin all variants ✓
- Reducer all delta kinds ✓
- State add_error, add_plugin, put_session ✓
- Delta.Store append, query, subscribe, persistence ✓
- Session CRUD ✓
- Effect.Executor register, execute, no-handler ✓
- Plugin.Manager register, unregister, list ✓
- Web router all routes ✓
- CLI parsing ✓
- Discord build_message_delta, parse_gateway_message ✓

**Not covered / gaps:**
- WebSocket (`/ws`) endpoint — no test for WebSocket upgrade or delta streaming (contains the C4 bug)
- `Kyber.Web.DeltaSocket` — zero test coverage
- LLM API actual call path — tested but mocked at HTTP level; the `handle_llm_call` private function has complex branching not fully exercised
- Discord WebSocket reconnection logic
- Store behavior under concurrent appends from multiple processes
- Error recovery after child process crashes
- `Kyber.Core` with actual plugin registration end-to-end
- Mix tasks (`kyber.emit`, `kyber.query`, `kyber.status`) — no tests at all

---

## Architecture Notes (Non-issues, Just Observations)

1. **The delta-driven unidirectional dataflow is clean.** Delta → Store → Reducer → State → Effects is a solid foundation. The immutable delta log gives you replay capability.

2. **Agent for State is fine at this scale** but will become a bottleneck if you need high-throughput state updates. ETS with `:protected` + GenServer writes would be faster.

3. **The plugin system is well-isolated.** DynamicSupervisor for plugins means a crashing plugin doesn't take down the core. Good call.

4. **Effect system is extensible.** The handler registry pattern makes it easy to add new effect types. The `async_nolink` usage in the Executor is correct — task failures don't crash the Executor.

5. **JSONL persistence** is a good choice for development — human-readable, append-only, easy to debug. Will need to be replaced with a real store (SQLite, ETS + WAL, or similar) for production use.

---

*Review complete. The critical items (C1-C4) should be addressed first — they represent silent failures in the core pipeline. The high items are important for reliability but won't cause immediate breakage in happy-path usage.*
