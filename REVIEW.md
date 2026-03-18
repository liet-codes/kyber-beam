# Kyber BEAM — Code Review

**Reviewer:** Staff Engineer  
**Date:** 2026-03-18  
**Phase:** 0+1 (initial architecture)  
**Test run:** `mix test` — 1 doctest, 160 tests, 0 failures ✅

---

## Summary

The overall architecture is clean and well-considered. The delta-driven unidirectional dataflow is a strong foundation, the supervision tree is structurally sound, and the code is readable with good documentation. The module boundaries are clear and the test coverage is solid for the happy paths.

However there are a handful of issues that need attention before this is production-ready — one functional bug (WebSocket delta delivery is silently broken), one architectural fragility that shows up as an error in the test log, and a security-adjacent concern in the LLM plugin.

---

## CRITICAL — Must fix before shipping

### C1. `Kyber.Web.DeltaSocket` — WebSocket never delivers deltas to clients

**File:** `lib/kyber_beam/web/router.ex`, lines 157–165  
**Confirmed:** No test exercises end-to-end WS delta delivery.

```elixir
def init(%{store: store}) do
  unsubscribe_fn = Kyber.Delta.Store.subscribe(store, fn delta ->
    send(self(), {:delta, delta})   # ← BUG: self() here is the Task, not the WS process
  end)
  {:ok, %{unsubscribe_fn: unsubscribe_fn}}
end
```

**What's wrong:** `self()` inside an anonymous function is evaluated at **call time**, not at closure definition time. The Store's `broadcast/2` calls each callback inside a `Task.start`. When the lambda executes, `self()` resolves to the *Task's* PID, not the WebSocket handler process. The `send` delivers the `{:delta, delta}` message to the Task (which ignores it), and the WebSocket handler's `handle_info({:delta, delta}, state)` is never triggered. The WS endpoint connects and stays connected but clients receive nothing.

**Why it matters:** This is a silently broken feature. The WebSocket endpoint exists, upgrades cleanly, but is functionally dead.

**Fix:**
```elixir
def init(%{store: store}) do
  ws_pid = self()   # capture here, in the WS process
  unsubscribe_fn = Kyber.Delta.Store.subscribe(store, fn delta ->
    send(ws_pid, {:delta, delta})   # ws_pid is a closed-over variable, not a call
  end)
  {:ok, %{unsubscribe_fn: unsubscribe_fn}}
end
```

---

### C2. `Kyber.Core.init/1` — Timing-dependent pipeline wiring; race confirmed in test output

**File:** `lib/kyber_beam/core.ex`, lines 116–120  
**Confirmed:** The following error appears in `mix test` output:

```
[error] Task #PID<0.575.0> started from :core_test_375794 terminating
** (stop) exited in: GenServer.call(:"core_test_375794.Store", {:subscribe, ...})
    ** (EXIT) no process: the process is not alive
```

```elixir
Task.start(fn ->
  Process.sleep(50)    # ← non-deterministic: assumes children ready within 50ms
  subscribe_reducer(core_name, store, state, executor)
end)
```

**What's wrong:** `Supervisor.init/1` returns a child spec to the Supervisor runtime, which *then* starts children. Children are not started until after `init/1` returns. The 50ms sleep is intended to wait for them to register, but this is a race: on a loaded system 50ms may not be enough, and during test teardown the store may already be dead before the task runs. If the subscription fails, the entire delta pipeline is silently unlinked — deltas are persisted but never reduce state or dispatch effects. The `Task.start` means the failure is not surfaced.

**Why it matters:** Silent pipeline failure is the worst failure mode for an event-driven system. Tests use `Process.sleep(100)` / `Process.sleep(150)` to compensate, which is a smell and hints this is a known issue.

**Fix:** Add a `Kyber.Core.PipelineWirer` GenServer as the last child in the supervisor. Since supervisors start children in order, when `PipelineWirer.init/1` runs, all prior siblings are already started and registered.

```elixir
# In Core.init/1, add as final child:
children = [
  {Task.Supervisor, name: task_sup},
  {Kyber.Delta.Store, [name: store, path: store_path]},
  {Kyber.State, [name: state]},
  {Kyber.Effect.Executor, [name: executor, task_supervisor: task_sup]},
  {Kyber.Plugin.Manager, [name: plugin_mgr]},
  # Wire last — all siblings are ready by the time this starts:
  {Kyber.Core.PipelineWirer, [store: store, state: state, executor: executor, core_name: core_name]}
]

# New module:
defmodule Kyber.Core.PipelineWirer do
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  def init(opts) do
    subscribe_reducer(...)
    :ignore   # or {:ok, nil} — this process has done its job
  end
end
```

Alternatively: have Core.init spawn the task but retry with exponential backoff and fail loudly rather than silently.

---

### C3. `Kyber.Plugin.LLM` — Auth token captured in closure at registration time; `update_auth` message has no effect

**File:** `lib/kyber_beam/plugin/llm.ex`, lines 198–211

```elixir
defp register_effect_handler(%{core: core, session: session, auth_config: auth_config}) do
  handler = fn effect ->
    handle_llm_call(effect, core, session, auth_config)   # ← auth_config frozen at registration time
  end
  Kyber.Core.register_effect_handler(core, :llm_call, handler)
end
```

And separately:
```elixir
def handle_info({:update_auth, auth_config}, state) do
  {:noreply, %{state | auth_config: auth_config}}   # ← updates state, but handler still uses old token
end
```

**What's wrong:** The `auth_config` (which contains the auth token) is baked into the handler closure at registration time. When auth is updated via `{:update_auth, ...}`, the GenServer state is updated but the already-registered handler closure still holds a reference to the old token. Token rotation effectively doesn't work.

**Why it matters:** Token expiry or rotation will cause all subsequent LLM calls to fail with auth errors, silently, until the plugin is restarted.

**Fix:** Don't close over `auth_config`. Instead, pass the GenServer's own `pid` so the handler can fetch the current config at call time:

```elixir
defp register_effect_handler(%{core: core, session: session}) do
  plugin_pid = self()
  handler = fn effect ->
    auth_config = GenServer.call(plugin_pid, :get_auth_config)
    handle_llm_call(effect, core, session, auth_config)
  end
  Kyber.Core.register_effect_handler(core, :llm_call, handler)
end

# Add to handle_call:
def handle_call(:get_auth_config, _from, state) do
  {:reply, state.auth_config, state}
end
```

---

## HIGH — Should fix

### H1. `Kyber.Delta.Store.broadcast/2` — Unsupervised tasks with no back-pressure

**File:** `lib/kyber_beam/delta/store.ex`, lines 140–144

```elixir
defp broadcast(%{subs: subs}, delta) do
  Enum.each(subs, fn {_id, callback_fn} ->
    Task.start(fn -> callback_fn.(delta) end)   # unsupervised, unbounded
  end)
end
```

**What's wrong:** `Task.start/1` creates tasks with no supervisor, no monitoring, and no lifecycle. If a subscriber is slow (e.g., the LLM handler making an HTTP call), tasks pile up with no limit. Errors inside callbacks are silently swallowed (beyond the Task itself dying). The Core's `subscribe_reducer` callback already has error handling, but the Task infrastructure underneath it has none.

**Fix:** Pass the `task_supervisor` name into the Store (like Executor does) and use `Task.Supervisor.start_child/2`:

```elixir
defp broadcast(%{subs: subs, task_sup: task_sup}, delta) do
  Enum.each(subs, fn {_id, callback_fn} ->
    Task.Supervisor.start_child(task_sup, fn -> callback_fn.(delta) end)
  end)
end
```

---

### H2. `Kyber.Delta.Store` — In-memory delta list grows unbounded; O(n) append

**File:** `lib/kyber_beam/delta/store.ex`, lines 80–82

```elixir
def handle_call({:append, delta}, _from, state) do
  :ok = write_line(state.path, delta)
  state = %{state | deltas: state.deltas ++ [delta]}   # O(n) and grows forever
```

**What's wrong:** Two issues:
1. `list ++ [element]` is O(n). For a store that accumulates thousands of deltas (realistic for a persistent bot), each append gets slower over time.
2. The in-memory list is never pruned. Memory grows indefinitely. The JSONL file is the source of truth; the in-memory list is just a query cache.

**Fix:** Keep the list in append-efficient order (prepend, reverse on read), and consider bounding the in-memory cache:

```elixir
# Store newest-first for O(1) prepend:
deltas: [delta | state.deltas]   # instead of ++ [delta]

# Reverse on query:
defp apply_limit(deltas, nil), do: Enum.reverse(deltas)
defp apply_limit(deltas, limit), do: deltas |> Enum.take(limit) |> Enum.reverse()
```

Or: drop the in-memory list entirely and read from disk on query (it's a JSONL file already).

---

### H3. `Kyber.Delta.Store.apply_limit/2` — Returns oldest deltas, not newest (semantic bug)

**File:** `lib/kyber_beam/delta/store.ex`, lines 133–135  
**Docstring says:** "newest-first after filtering"

```elixir
defp apply_limit(deltas, nil), do: deltas
defp apply_limit(deltas, limit), do: Enum.take(deltas, limit)   # takes from the front = oldest
```

**What's wrong:** Deltas are stored oldest-first. `Enum.take(deltas, limit)` returns the first N — the *oldest* — not the newest. With `limit: 5` you get the 5 oldest deltas. This is almost certainly the opposite of what callers expect.

**Fix:**
```elixir
defp apply_limit(deltas, nil), do: deltas
defp apply_limit(deltas, limit), do: deltas |> Enum.take(-limit)  # take from end = newest
```

---

### H4. `Kyber.Session.handle_call/3` — O(n) history appending; O(n) ETS read for each append

**File:** `lib/kyber_beam/session.ex`, lines 63–70

```elixir
def handle_call({:add_message, chat_id, delta}, _from, %{table: table} = state) do
  history =
    case :ets.lookup(table, chat_id) do
      [{^chat_id, existing}] -> existing
      [] -> []
    end
  :ets.insert(table, {chat_id, history ++ [delta]})   # O(n)
```

**What's wrong:** Every `add_message` reads the full history from ETS, appends to the end (O(n)), and writes the whole list back. For a session with 100 messages, each append copies 100 elements. Long sessions become quadratically expensive.

**Fix:** Store history newest-first (prepend is O(1)), reverse on read:

```elixir
def handle_call({:add_message, chat_id, delta}, _from, %{table: table} = state) do
  history = case :ets.lookup(table, chat_id) do
    [{^chat_id, existing}] -> existing
    [] -> []
  end
  :ets.insert(table, {chat_id, [delta | history]})   # O(1)
  {:reply, :ok, state}
end

def get_history(pid \\ __MODULE__, chat_id) when is_binary(chat_id) do
  table = table_name(pid)
  case :ets.lookup(table, chat_id) do
    [{^chat_id, history}] -> Enum.reverse(history)   # reverse on read
    [] -> []
  end
end
```

---

### H5. `Kyber.Core.subscribe_reducer/4` — Only rescues exceptions; exits/throws propagate

**File:** `lib/kyber_beam/core.ex`, lines 127–143

```elixir
effects =
  try do
    Kyber.State.get_and_update(state, fn current_state ->
      {new_state, effects} = Kyber.Reducer.reduce(current_state, delta)
      {effects, new_state}
    end)
  rescue
    e -> ...  # only catches Exception.t()
  end
```

**What's wrong:** `rescue` only catches Elixir exceptions (`raise`). If the reducer or state agent throws (`:throw`) or exits (`:exit`), the `try` won't catch it, and the subscriber task (spawned by `Task.start` in `broadcast`) will crash with no recovery. In OTP terms, an `:exit` from `GenServer.call` (e.g., timeout) will propagate up.

**Fix:**
```elixir
try do
  Kyber.State.get_and_update(...)
rescue
  e ->
    Logger.error(...)
    []
catch
  :exit, reason ->
    Logger.error("[Kyber.Core/#{inspect(core_name)}] reducer exit: #{inspect(reason)}")
    []
  kind, reason ->
    Logger.error("[Kyber.Core/#{inspect(core_name)}] reducer #{kind}: #{inspect(reason)}")
    []
end
```

---

### H6. `KyberBeam.Application` — `Kyber.Session` not under `Kyber.Core`; state drift on Core restart

**File:** `lib/kyber_beam/application.ex`, lines 12–15

```elixir
children = [
  {Kyber.Session, name: Kyber.Session},
  {Kyber.Core, name: Kyber.Core}
]
opts = [strategy: :one_for_one, name: KyberBeam.Supervisor]
```

**What's wrong:** `Kyber.Session` and `Kyber.Core` are independent siblings under `one_for_one`. If `Kyber.Core` crashes and restarts, it gets a fresh `Kyber.State` but `Kyber.Session` retains all its history. The Core's state says no sessions, but Session has history from before the crash. This creates a split-brain between application state and session history.

**Why it matters:** The LLM plugin's `handle_llm_call` reads session history to build context. After a Core restart, the state is reset but sessions aren't cleared, so the LLM gets stale context with no corresponding state entries.

**Decision to make:** Either:
1. Make Session a child of Core so it resets together (correct if session history is derived from Core state)
2. Or keep them separate but add logic to reconcile state on Core startup
3. Or use `rest_for_one` strategy so Session is restarted if Core restarts

---

### H7. `Kyber.Plugin.LLM` — Hardcoded personal auth path; not configurable per deployment

**File:** `lib/kyber_beam/plugin/llm.ex`, line 19

```elixir
@auth_profiles_path "~/.openclaw/agents/main/agent/auth-profiles.json"
```

**What's wrong:** This is a hardcoded path to the developer's own OpenClaw installation. It bakes a personal file structure into library code. Anyone else trying to use this project will get `{:error, :enoent}` immediately and the plugin will run degraded without auth (silently — just a warning log).

**Fix:** Make this configurable via app env with the personal path as a reasonable default that's clearly documented:

```elixir
@default_auth_path "~/.openclaw/agents/main/agent/auth-profiles.json"

# In init:
auth_path = Keyword.get(opts, :auth_path) ||
            Application.get_env(:kyber_beam, :auth_profiles_path, @default_auth_path)
```

---

### H8. `Kyber.Delta.Store.write_line/2` — `File.write!` raises, crashing the GenServer on disk failure

**File:** `lib/kyber_beam/delta/store.ex`, lines 123–126

```elixir
defp write_line(path, delta) do
  json = Jason.encode!(Kyber.Delta.to_map(delta))
  File.write!(path, json <> "\n", [:append])   # raises on disk full, permissions, etc.
  :ok
end
```

**What's wrong:** `File.write!/3` raises `File.Error` on any IO failure (disk full, read-only filesystem, path disappears). This exception propagates from inside `handle_call({:append, ...})`, crashing the GenServer. The supervisor will restart it, but any in-memory state and all pending subscribers are lost.

**Fix:**
```elixir
defp write_line(path, delta) do
  json = Jason.encode!(Kyber.Delta.to_map(delta))
  case File.write(path, json <> "\n", [:append]) do
    :ok -> :ok
    {:error, reason} ->
      Logger.error("[Kyber.Delta.Store] write failed: #{inspect(reason)}")
      {:error, reason}
  end
end

# In handle_call({:append, ...}):
case write_line(state.path, delta) do
  :ok ->
    state = %{state | deltas: [delta | state.deltas]}
    broadcast(state, delta)
    {:reply, :ok, state}
  {:error, reason} ->
    {:reply, {:error, reason}, state}
end
```

Note: `Kyber.Core.emit/2` currently expects `:ok` and will need updating to handle `{:error, reason}`.

---

## MEDIUM — Improve

### M1. Dead module attribute: `@registry` in `Kyber.Delta.Store`

**File:** `lib/kyber_beam/delta/store.ex`, line 16  
**Compiler confirms:** `warning: module attribute @registry was set but never used`

```elixir
@registry Kyber.Delta.Store.Registry   # never used
```

Looks like a Registry-based PubSub was the original plan. Either implement it or remove the attribute. The current `subs` map in GenServer state works fine for the current scale.

---

### M2. Dead module attribute: `@gateway_url` in `Kyber.Plugin.Discord`

**File:** `lib/kyber_beam/plugin/discord.ex`, line 27  
**Compiler confirms:** `warning: module attribute @gateway_url was set but never used`

```elixir
@gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"   # defined but never referenced
```

The `handle_info(:connect, state)` callback logs "connecting to gateway" but doesn't actually use `@gateway_url`. Either wire it into a real WebSocket client or leave a clear TODO comment explaining it's a stub.

---

### M3. `Kyber.Reducer` — Discord-channel-specific routing in a channel-agnostic reducer

**File:** `lib/kyber_beam/reducer.ex`, lines 37–51

```elixir
channel_id =
  case delta.origin do
    {:channel, "discord", cid, _} -> cid   # only Discord; Slack/Telegram will silently drop
    _ -> nil
  end
```

**What's wrong:** The reducer is supposed to be pure and platform-agnostic, but it has `"discord"` hardcoded as a channel name. If a Slack or Telegram plugin is added, `llm.response` deltas will always produce no `send_message` effect because `channel_id` will be `nil`. This is a silent failure.

**Fix:** Route to any channel origin generically:

```elixir
channel_id =
  case delta.origin do
    {:channel, _platform, cid, _} -> cid   # any channel platform
    _ -> nil
  end
```

The effect payload already contains the full origin, so the per-platform plugin can figure out how to send the message.

---

### M4. `Kyber.Web.Router.store_pid/0` — Process dictionary used for test injection

**File:** `lib/kyber_beam/web/router.ex`, lines 85–89

```elixir
defp store_pid do
  Process.get(:kyber_store_pid) || Kyber.Delta.Store
end
```

**What's wrong:** Using process dictionary for dependency injection is a code smell. It couples tests to process state and makes the dependency invisible at the call site. Router tests set `Process.put(:kyber_store_pid, store)` in setup.

**Suggested alternative:** Use `Application.get_env/3` or pass the store name as a Plug option via `conn.assigns` or an init option:

```elixir
plug :match
plug :fetch_query_params
plug Plug.Parsers, parsers: [:json], json_decoder: Jason
plug :dispatch

# In start_link / child_spec, accept :store_name opt and store in :assigns
```

Or at minimum, document the process dictionary key as a test-only mechanism.

---

### M5. `Kyber.Plugin.Discord` — Always registers as `__MODULE__`; can't run multiple instances

**File:** `lib/kyber_beam/plugin/discord.ex`, line 57

```elixir
def start_link(opts \\ []) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)   # always Kyber.Plugin.Discord
end
```

**What's wrong:** Plugin Manager uses `DynamicSupervisor.start_child/2`, which allows multiple instances of a plugin type in theory. But the Discord plugin hardcodes its registered name to `Kyber.Plugin.Discord`. A second instance would immediately fail with `{:error, {:already_started, pid}}`. The Manager handles this by returning `{:ok, pid}` (which looks like success), so the caller doesn't know it got the original process.

**Fix:** Accept a `:name` option like other components:

```elixir
def start_link(opts \\ []) do
  name = Keyword.get(opts, :name, __MODULE__)
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

---

### M6. `Kyber.State.add_error/2` — Unbounded error list with O(n) append

**File:** `lib/kyber_beam/state.ex`, lines 75–77

```elixir
def add_error(%__MODULE__{} = state, error) when is_map(error) do
  %{state | errors: state.errors ++ [error]}   # unbounded, O(n)
end
```

The errors list grows indefinitely. In a long-running bot, the State agent will accumulate every error forever. Suggest bounding it (e.g., keep last 100):

```elixir
@max_errors 100
def add_error(%__MODULE__{} = state, error) when is_map(error) do
  errors = [error | state.errors] |> Enum.take(@max_errors)
  %{state | errors: errors}
end
```

---

### M7. `KyberBeam` root module — Stub left over from `mix new`

**File:** `lib/kyber_beam.ex`

```elixir
defmodule KyberBeam do
  def hello, do: :world
end
```

This module serves no purpose. Either delete it or replace with useful top-level convenience functions (start, emit, query) that make the library easy to use from a Mix shell or iex.

---

### M8. Gateway intents comment is contradictory and incorrect

**File:** `lib/kyber_beam/plugin/discord.ex`, lines 33–39

```elixir
# Intents: GUILDS (1) | GUILD_MESSAGES (512) | MESSAGE_CONTENT (32768) = 33281
# Actually: GUILDS=1, GUILD_MESSAGES=512, MESSAGE_CONTENT=32768 → 1+512+32768 = 33281
# But the spec says 34307 which is GUILDS(1) + GUILD_MESSAGES(512) + MESSAGE_CONTENT(32768) + DIRECT_MESSAGES(4096) = 37377? 
# Let's use 34307 as specified
@gateway_intents 34307
```

The comment contradicts itself. 34307 in binary is `1000010111000011` which equals `32768 + 1024 + 256 + 128 + 64 + 32 + 16 + 8 + 4 + 2 + 1` — it's not a clean sum of standard intent flags. This suggests copy-paste from another source without verification.

Recommend computing it explicitly:

```elixir
# Discord Gateway Intents (v10)
# See: https://discord.com/developers/docs/topics/gateway#gateway-intents
@intent_guilds        0x0001   # 1
@intent_guild_messages 0x0200  # 512
@intent_message_content 0x8000 # 32768
@intent_direct_messages 0x1000 # 4096

@gateway_intents @intent_guilds ||| @intent_guild_messages ||| @intent_message_content ||| @intent_direct_messages
```

---

## LOW — Nice to have

### L1. `mix.exs` — deprecated `preferred_cli_env` in `def project`

```
warning: setting :preferred_cli_env in your mix.exs "def project" is deprecated,
set it inside "def cli" instead
```

Move to:
```elixir
def cli do
  [preferred_envs: [coveralls: :test]]
end
```

---

### L2. `use Plug.Test` deprecated in test file

**File:** `test/kyber_beam/web/router_test.exs`, line 3

```
warning: use Plug.Test is deprecated. Please use `import Plug.Test` and `import Plug.Conn` directly
```

---

### L3. `Kyber.Delta.Origin.deserialize/1` — fallback leaks internal `inspect/1` output

**File:** `lib/kyber_beam/delta.ex`, lines 136–138

```elixir
def deserialize(other) do
  {:system, "unknown:#{inspect(other)}"}
end
```

`inspect/1` output on an unknown origin map (e.g., from a malformed API request) will produce Elixir syntax strings stored in the delta log. For a published service this could leak internal type info. Consider logging the bad input and returning `{:system, "unknown"}` instead.

---

### L4. `Kyber.Plugin.LLM.extract_token/1` — Recursive search is overly broad

**File:** `lib/kyber_beam/plugin/llm.ex`, lines 290–303

The fallback clause does a depth-first recursive scan of the entire auth JSON looking for any string with `byte_size > 20` that starts with `"sk-ant-"`. This is fragile and could match unexpected fields in a deeply nested config. The explicit pattern matches above it cover all known formats — the recursive fallback adds risk without meaningful gain. Consider removing it or limiting the recursion depth.

---

### L5. Core test uses `Process.sleep` for timing — tests are fragile

**Files:** `test/kyber_beam/core_test.exs` (multiple tests)

```elixir
Process.sleep(100)  # let subscription wire up
Process.sleep(150)  # let subscription wire up (wires at 50ms)
Process.sleep(300)  # ...
```

Once C2 (pipeline wiring race) is fixed, these sleeps can be replaced with synchronous guarantees. As-is, these tests could occasionally flake on a very slow CI machine. After fixing C2, tests should be able to assert pipeline readiness deterministically.

---

## Appendix: Quick-win checklist

| # | File | Fix | Effort |
|---|------|-----|--------|
| C1 | `web/router.ex:159` | `ws_pid = self()` before closure | 1 line |
| C2 | `core.ex:116` | Add `PipelineWirer` child | ~20 lines |
| C3 | `plugin/llm.ex:198` | Read auth from GenServer at call time | ~10 lines |
| H3 | `delta/store.ex:134` | `Enum.take(-limit)` | 1 line |
| H5 | `core.ex:127` | Add `catch` clauses | ~5 lines |
| M3 | `reducer.ex:44` | `{:channel, _, cid, _}` | 1 line |
| L1 | `mix.exs` | Move to `def cli` | 3 lines |
| L2 | `router_test.exs:3` | `import Plug.Test` | 2 lines |

---

*Review complete. All 160 tests pass. No test failures introduced by findings — these are correctness and quality issues not yet exercised by the test suite.*
