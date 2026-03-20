# kyber-beam Architecture Audit

**Reviewer:** Staff-level Elixir Architect  
**Date:** 2026-03-20  
**Codebase:** `/Users/liet/kyber-beam`  
**Scope:** Full audit — OTP patterns, state management, error handling, module boundaries, configuration, performance, testing, naming/docs

---

## Executive Summary

kyber-beam is a well-structured Elixir/OTP agent harness with clear architectural intent. The core data-flow design (Delta → Store → Reducer → Effect → Executor) is sound and idiomatic. `Kyber.Core`'s `:rest_for_one` supervision strategy and the `PipelineWirer` last-child startup pattern show real OTP maturity.

The main concerns cluster around three themes:
1. **Partial OTP compliance at the application level** — the top-level supervisor strategy doesn't protect against Core restarts breaking plugin state.
2. **Blocking I/O and O(n) operations in GenServer callbacks** — a few paths that look harmless on a dev machine will degrade noticeably under load.
3. **Test fragility** — widespread use of `Process.sleep` for async coordination is a flakiness factory.

There are no systemic design failures. Most issues have clean fixes.

---

## Supervision Tree Map

```
KyberBeam.Supervisor (:one_for_one)           ← application.ex
├── Phoenix.PubSub
├── Kyber.Session                              ← GenServer + owns ETS table
├── Kyber.Core (:rest_for_one)                ← nested supervisor
│   ├── Task.Supervisor (Kyber.Core.TaskSupervisor)
│   ├── Kyber.Delta.Store                     ← GenServer, JSONL + subscriptions
│   ├── Kyber.State                           ← Agent
│   ├── Kyber.Effect.Executor                 ← GenServer, handler registry
│   ├── Kyber.Plugin.Manager (DynamicSupervisor)
│   └── Kyber.Core.PipelineWirer              ← GenServer, wires Store→Reducer→Executor
├── Kyber.Deployment
├── Kyber.Knowledge                           ← GenServer, vault + ETS notes
├── Kyber.Cron                                ← GenServer, 1s tick
├── Kyber.Memory.Consolidator                 ← GenServer + ETS pool
├── Kyber.Plugin.LLM                          ← GenServer (NOT under PluginManager)
├── Kyber.Plugin.Discord                      ← GenServer (NOT under PluginManager)
├── Kyber.Web.Server / Kyber.Web.Endpoint
└── Kyber.Distribution
```

**Note:** `Kyber.Plugin.LLM` and `Kyber.Plugin.Discord` are started directly in the application supervisor, NOT via `Kyber.Plugin.Manager`. This means they are not dynamically manageable and do not appear in `Core.list_plugins/1`. This is an inconsistency described further under MEDIUM findings.

---

## Findings

### CRITICAL

---

#### C1 — Unsupervised bare `spawn` in `application.ex:64`

**File:** `lib/kyber_beam/application.ex:64`

```elixir
spawn(fn ->
  Process.sleep(2_000)
  monitor_delta_store()
end)
```

`monitor_delta_store/0` recurses indefinitely — it's a permanent loop spawned with `spawn/1`. This is an unlinked, unmonitored process. If it crashes (e.g., an exception in `Process.info/2` for a dead pid), it silently disappears with no logging and no restart. It's also a process leak vector: if the application restarts, a new unlinked loop is spawned without cleaning up the old one.

This code appears to be a debugging artifact from tracking a Delta.Store crash. It should be removed entirely in production, or if monitoring is genuinely needed, replaced with a proper supervised GenServer.

**Fix:**
```elixir
# Remove the spawn block entirely.
# If crash-monitoring is needed, add a supervised GenServer or use
# :telemetry + :logger_handler for process death events.
```

---

#### C2 — `Delta.Store.init/1` crashes on file-open failure, causing restart loop

**File:** `lib/kyber_beam/delta/store.ex:89`

```elixir
{:ok, io_device} = File.open(path, [:append, :binary])
```

This pattern-match raises `MatchError` if the file can't be opened (permissions error, path not creatable, disk full). Because `Kyber.Core` uses `:rest_for_one`, a crashing `Delta.Store` restarts all subsequent children (State, Executor, PluginManager, PipelineWirer). Under `:rest_for_one` with the default `max_restarts: 10`, 10 consecutive file-open failures shut down the entire `Kyber.Core` supervisor, which then escalates up to `KyberBeam.Supervisor`.

**Fix:** Return `{:stop, reason}` from `init/1` on file-open failure so the error is clear and logged:
```elixir
case File.open(path, [:append, :binary]) do
  {:ok, io_device} ->
    {:ok, %{..., io_device: io_device}}
  {:error, reason} ->
    Logger.error("[Kyber.Delta.Store] cannot open #{path}: #{inspect(reason)}")
    {:stop, {:file_open_failed, reason}}
end
```

---

#### C3 — Blocking disk I/O inside `Delta.Store.handle_call({:query, ...})`

**File:** `lib/kyber_beam/delta/store.ex:128–144`

```elixir
def handle_call({:query, filters}, _from, state) do
  deltas =
    if needs_disk_fallback?(state.deltas, since) do
      load_from_disk(state.path)   # ← synchronous, full file read
    else
      state.deltas
    end
  ...
```

`load_from_disk/1` reads the entire JSONL file synchronously inside `handle_call`. For a file with hundreds of thousands of entries (the `cron.fired` issue was previously causing 400K+ deltas in 42 hours), this can block the Store GenServer for seconds. While the Store is blocked:
- All `append/2` calls queue up
- All `broadcast_only/2` calls queue up (Cron starves)
- `PipelineWirer` subscriber tasks pile up waiting for Store replies

**Fix:** Offload disk reads to a `handle_call → Task` pattern, or better, maintain a persistent `ReaderState` that allows async disk fallback without blocking the GenServer. Short-term: add a `timeout` guard and cache the last disk-load result with a TTL.

---

### HIGH

---

#### H1 — `KyberBeam.Supervisor` `:one_for_one` doesn't protect Core-dependent plugins

**File:** `lib/kyber_beam/application.ex:58`

```elixir
opts = [strategy: :one_for_one, name: KyberBeam.Supervisor, max_restarts: 10, max_seconds: 60]
```

`Kyber.Plugin.LLM` registers an `:llm_call` effect handler with `Kyber.Core`'s executor during its `init/1`. If `Kyber.Core` crashes and restarts, a new `Kyber.Effect.Executor` process starts with a **blank handler registry**. The LLM plugin is NOT restarted (`:one_for_one` only restarts the crashed child). From this point on, no `llm_call` effects are dispatched — the system silently stops responding to messages.

This is the most operationally dangerous issue in the codebase.

**Fix 1 (surgical):** Change the top-level strategy to `:rest_for_one` and move `Kyber.Plugin.LLM` and `Kyber.Plugin.Discord` to AFTER `Kyber.Core` in the children list. This ensures they restart whenever Core restarts.

**Fix 2 (better long-term):** Have the LLM plugin monitor `Kyber.Core` and re-register its effect handler on `{:DOWN, ...}`. This makes the handler registration resilient regardless of supervisor strategy.

---

#### H2 — ETS access in `Session.get_history` races with GenServer crash

**File:** `lib/kyber_beam/session.ex:37–41`

```elixir
def get_history(pid \\ __MODULE__, chat_id) when is_binary(chat_id) do
  table = table_name(pid)
  case :ets.lookup(table, chat_id) do    # ← crashes with :badarg if table gone
    [{^chat_id, history}] -> history
    [] -> []
  end
end
```

This reads ETS directly (bypassing GenServer) for performance. The table is created with `:named_table` in the GenServer's `init/1` and deleted in `terminate/2`. If the GenServer is between "crashed" and "restarted" (its table was deleted), `:ets.lookup/2` raises `{:badarg, table_name}`. This exception propagates to the caller with no protection. The LLM plugin calls `get_history` from inside a supervised Task — but the Task crash logs an error and drops the effect silently.

The `:public` access flag is also worth noting: any process can write to the sessions table directly, bypassing the write serialization the GenServer provides.

**Fix:** Use `try/rescue` around the ETS lookup, or add an `ets_safe_lookup/2` wrapper. Consider removing `:public` and routing all writes through the GenServer (reads are already fast via ETS).

---

#### H3 — Unbounded `state.errors` list in `Kyber.State`

**File:** `lib/kyber_beam/state.ex:89–91`

```elixir
def add_error(%__MODULE__{} = state, error) when is_map(error) do
  %{state | errors: state.errors ++ [error]}
end
```

Each `llm.error` or `error.route` delta appends to `state.errors`. There is no cap, no trimming, and no eviction. Under error conditions (network down, API failures), this list grows without bound. Since `Kyber.State` is an Agent, the entire state map is serialized on each `get/update` call — a large errors list significantly increases the cost of every state access.

**Fix:**
```elixir
@max_errors 100

def add_error(%__MODULE__{} = state, error) when is_map(error) do
  trimmed = Enum.take(state.errors ++ [error], -@max_errors)
  %{state | errors: trimmed}
end
```

---

#### H4 — `Kyber.Plugin.LLM` hardcodes its own process name, preventing multiple instances

**File:** `lib/kyber_beam/plugin/llm.ex:46`

```elixir
def start_link(opts \\ []) do
  GenServer.start_link(__MODULE__, opts, name: __MODULE__)
end
```

`name: __MODULE__` (`:Kyber.Plugin.LLM`) is hardcoded. Unlike every other module in the codebase, `Plugin.LLM` does not accept a `:name` option. This means:
1. Only one LLM plugin can run per node
2. The `Kyber.Plugin.Manager` cannot manage it (it has no `:name` override path)
3. Hot-reloading via `Plugin.Manager.reload/2` won't work for this plugin

**Fix:** Accept `name` from opts, defaulting to `__MODULE__`:
```elixir
def start_link(opts \\ []) do
  {name, opts} = Keyword.pop(opts, :name, __MODULE__)
  GenServer.start_link(__MODULE__, opts, name: name)
end
```

---

#### H5 — `Delta.Store.terminate` logs `:error` for all shutdown reasons including `:normal`

**File:** `lib/kyber_beam/delta/store.ex:172–185`

```elixir
def terminate(reason, state) do
  Logger.error("[Kyber.Delta.Store] TERMINATING - reason: #{inspect(reason)}")
  ...
```

Normal supervisor shutdown (`:normal`, `:shutdown`, `{:shutdown, _}`) logs at `:error` level. This creates false alarm noise in production logs and makes it impossible to distinguish expected teardown from genuine crashes. The `AppMonitor` spawn exists precisely because this log level was misleading.

**Fix:**
```elixir
def terminate(reason, state) do
  level = if reason in [:normal, :shutdown], do: :info, else: :error
  Logger.log(level, "[Kyber.Delta.Store] terminating: #{inspect(reason)}")
  if io = Map.get(state, :io_device), do: File.close(io)
  :ok
end
```

---

#### H6 — `Kyber.Knowledge.init/1` synchronous vault load blocks startup

**File:** `lib/kyber_beam/knowledge.ex`

`init/1` calls `load_vault_sync(state)` which walks the entire vault directory, reads all `.md` files, parses YAML frontmatter, extracts wikilinks, and builds a link graph — all synchronously before `{:ok, state}` is returned. For a large vault, this delays the supervisor from completing startup, and all children started after Knowledge in `KyberBeam.Supervisor` are blocked.

**Fix:** Use `{:ok, state, {:continue, :load_vault}}` to defer the load:
```elixir
def init(opts) do
  state = %{vault_path: ..., notes: %{}, ...}
  {:ok, state, {:continue, :load_vault}}
end

def handle_continue(:load_vault, state) do
  new_state = load_vault_sync(state)
  {:noreply, new_state}
end
```

---

### MEDIUM

---

#### M1 — `Kyber.State.add_error/2` and `Session.add_message/3` use `list ++ [elem]` (O(n))

**Files:** `lib/kyber_beam/state.ex:90`, `lib/kyber_beam/session.ex:83`

```elixir
# state.ex
%{state | errors: state.errors ++ [error]}

# session.ex
:ets.insert(table, {chat_id, history ++ [delta]})
```

`list ++ [element]` copies the entire left list to append one element. For `state.errors` (already fixed if H3 is addressed), this is minor. For session history — which grows with every message in a conversation — a session with 100 messages copies 100 elements per `add_message` call.

**Fix:** Accumulate in reverse, reverse on read:
```elixir
# Write: O(1)
:ets.insert(table, {chat_id, [delta | existing_history_reversed]})

# Read: O(n) once, at the end
history = :ets.lookup... |> Enum.reverse()
```

Or use an `:ordered_set` with monotonic integer keys.

---

#### M2 — `Kyber.Plugin.LLM` and `Kyber.Plugin.Discord` not managed by `Plugin.Manager`

**File:** `lib/kyber_beam/application.ex:41–49`

Both core plugins are started directly in `KyberBeam.Supervisor`, not via `Kyber.Plugin.Manager`. This creates:
- An inconsistency: `Core.list_plugins/1` returns `[]` even when LLM and Discord are running
- No ability to `reload/unregister` them via the Plugin API
- A documentation gap (`@moduledoc` for `Plugin.Manager` implies plugins use it)

These plugins depend on `Kyber.Core` and `Kyber.Session` being alive — which is exactly what `Kyber.Plugin.Manager` (under `Kyber.Core`) provides. The correct place for them may be registered after Core starts, or they should be bootstrapped differently.

---

#### M3 — `ToolExecutor.@allowed_write_roots` expanded at compile time

**File:** `lib/kyber_beam/tool_executor.ex:25–30`

```elixir
@allowed_write_roots [
  Path.expand("~/.kyber"),
  Path.expand("~/kyber-beam"),
  System.tmp_dir!()
]
```

`Path.expand("~")` and `System.tmp_dir!()` are evaluated at compile time (module attribute). If compiled in a CI environment where `$HOME` differs from runtime, the allowed roots won't match reality. This is a latent security bug: write attempts to the real `~/.kyber` at runtime would be wrongly rejected (or worse, wrongly permitted in a different home dir).

**Fix:** Use a function or `Application.get_env/3` evaluated at runtime:
```elixir
defp allowed_write_roots do
  [
    Path.expand("~/.kyber"),
    Path.expand("~/kyber-beam"),
    System.tmp_dir!()
  ]
end
```

---

#### M4 — `Kyber.Cron` 1Hz tick is a synchronous call chain

**File:** `lib/kyber_beam/cron.ex`

Every second, `handle_info(:check_jobs)` runs and calls `Core.emit/2` for each fired job. `Core.emit/2` calls `Delta.Store.broadcast_only/2` (or `append/2`), which is a synchronous `GenServer.call`. If the Store is slow (e.g., under load from C3 above), the Cron GenServer's mailbox accumulates `:check_jobs` messages. Eventually Cron falls behind real time and fires jobs late.

**Fix:** Use `cast` instead of `call` for emission paths where ordering doesn't matter, or use `handle_cast` for the check tick to prevent mailbox accumulation. At minimum, add a mailbox-length check to detect when Cron is falling behind.

---

#### M5 — `Effect.Executor`'s `@known_effect_types` requires code change to add new types

**File:** `lib/kyber_beam/effect.ex:77–85`

```elixir
@known_effect_types ~w(
  llm_call
  discord_message
  error_route
  plugin_loaded
  message_received
)a
```

This list guards `safe_to_atom/1`. Adding a new effect type requires modifying `Kyber.Effect.Executor`, creating an unnecessary coupling between the Executor (infrastructure) and effect type definitions (domain). Any plugin that introduces a new string-typed effect needs to touch this core module.

**Fix:** Either document that plugins should use atom keys from the start (not strings), or pass the known types list via config/opts at startup.

---

#### M6 — `Kyber.Memory.Consolidator` O(n) ETS scan per vault-ref lookup

**File:** `lib/kyber_beam/memory/consolidator.ex`

`find_by_vault_ref/2` (called from `list_memories/0` and consolidation logic) does a full `:ets.tab2list` scan to find entries by vault_ref. The `@moduledoc` notes "Pool is small" as justification, but this is an assumption without enforcement. There is no pool size cap. A user with hundreds of memory entries will see increasing latency on every vault change.

**Fix:** Add a secondary ETS index keyed by `{:vault_ref, ref}` for O(1) lookup, or enforce a `@max_pool_size` constant with eviction on overflow.

---

#### M7 — `Kyber.Distribution` referenced in application supervisor without comment

**File:** `lib/kyber_beam/application.ex:56`

```elixir
|> then(&(&1 ++ [{Kyber.Distribution, name: Kyber.Distribution}]))
```

The inline comment says "LAST — subscribes to Core's children" but gives no explanation of what `Kyber.Distribution` does, why it must be last, or what it subscribes to. The module itself is reasonably documented but the application startup comment is cryptic.

---

#### M8 — `Kyber.Session` table is `:public` — write bypass possible

**File:** `lib/kyber_beam/session.ex:70`

```elixir
:ets.new(table, [:named_table, :public, :set, read_concurrency: true])
```

`:public` allows any process to write to the session table directly. The GenServer is the intended serialization point for writes (for ordering guarantees). With `:public`, another process could corrupt session history by writing directly. `:protected` (default) would allow any process to read but only the owning GenServer to write, which matches the intended access pattern.

**Fix:** Change to `:protected`. `get_history/2` already reads ETS directly (efficient), but the only current writer is the GenServer, so `:protected` is the right access level.

---

### LOW

---

#### L1 — `KyberBeam.Application` module name inconsistent with `Kyber.*` convention

**File:** `lib/kyber_beam/application.ex:1`

```elixir
defmodule KyberBeam.Application do
```

Every other module uses the `Kyber.` namespace. The Application callback is `KyberBeam.Application`. While functionally irrelevant (the `mix.exs` mod config drives which is called), the inconsistency is jarring when reading the codebase.

---

#### L2 — `@missed_threshold_ms` hardcoded in `Kyber.Cron`

**File:** `lib/kyber_beam/cron.ex`

```elixir
@missed_threshold_ms 5_000
```

This isn't configurable at startup. For systems that suspend frequently (laptops), 5 seconds may be too tight and generate false "missed" delta noise. Should be configurable via opts.

---

#### L3 — `Kyber.Familiard.parse_escalation` silently discards `context` and `timestamp` on validation failure

**File:** `lib/kyber_beam/familiard.ex`

The `with` pipeline in `parse_escalation/1` only validates `level` and `message`. If either fails, the entire event is dropped. The caller gets `{:error, :invalid_level}` or `{:error, :invalid_message}` but no indication of which fields were valid. For a webhook endpoint, this makes debugging bad payloads unnecessarily hard.

---

#### L4 — `Kyber.Tools.definitions/0` is a large static list with no versioning

**File:** `lib/kyber_beam/tools.ex`

The tools definition list is returned as-is on every LLM call. There is no mechanism to add/remove tool definitions at runtime (e.g., based on which plugins are active). Tools like `memory_pin` require `Memory.Consolidator` to be running; if it isn't, the tool executes but fails. The tool list should reflect actual capability.

---

#### L5 — `Kyber.Delta.Origin.deserialize` has a catch-all that loses type information

**File:** `lib/kyber_beam/delta.ex`

```elixir
def deserialize(other) do
  {:system, "unknown:#{inspect(other)}"}
end
```

If a new origin type is added and the deserializer isn't updated, old stored deltas with the new type silently become `{:system, "unknown: ..."}`. This is a backwards-compatibility trap. Consider raising or logging an error to surface the mismatch early.

---

#### L6 — `yaml_value/1` in `Kyber.Knowledge` is incomplete

**File:** `lib/kyber_beam/knowledge.ex`

The YAML frontmatter serializer only handles strings and lists. Integer and boolean values in frontmatter (e.g., `priority: 1`, `pinned: true`) are serialized as Elixir-inspect strings, not valid YAML. Round-tripping a note with non-string frontmatter will corrupt it.

---

## Testing Findings

### T1 — `Process.sleep` for async coordination (HIGH flakiness risk)

**Files:** `test/kyber_beam/core_test.exs`, `test/kyber_beam/knowledge_test.exs`, others

```elixir
Core.emit(name, delta)
Process.sleep(100)               # ← timing assumption
state = Core.get_state(name)
assert "test_plugin" in state.plugins
```

The delta-to-state pipeline is: `emit → Store.append (GenServer.call) → Task.start broadcast → PipelineWirer callback Task → State.get_and_update (Agent.call)`. The whole chain is async after the initial `GenServer.call`. `Process.sleep(100)` is a timing assumption that will fail on a slow CI machine or under heavy load.

**Fix:** Use `assert_receive` for effect-triggered tests, or add a `wait_until/2` helper that polls with `Process.sleep(10)` up to a timeout:
```elixir
def wait_until(fun, timeout \\ 1000) do
  deadline = System.monotonic_time(:millisecond) + timeout
  do_wait_until(fun, deadline)
end
defp do_wait_until(fun, deadline) do
  if fun.() do
    :ok
  else
    if System.monotonic_time(:millisecond) < deadline do
      Process.sleep(10)
      do_wait_until(fun, deadline)
    else
      flunk("wait_until timed out")
    end
  end
end
```

---

### T2 — `knowledge_test.exs` uses `async: true` with Process.sleep for file-watcher tests

**File:** `test/kyber_beam/knowledge_test.exs:2`

`async: true` with `Process.sleep(1100)` (waiting for the polling interval) creates flaky timing windows when multiple async test processes run in parallel. The 1100ms sleep assumes the file watcher polls on exactly a 1000ms boundary. This should be `async: false`, or the polling interval should be configurable per-test.

---

### T3 — No integration tests for the Core → Plugin.LLM handler registration flow

The scenario identified in H1 (Core restart orphaning LLM handler registration) has no test coverage. The `core_test.exs` tests Core in isolation and `llm_test.exs` tests the LLM plugin in isolation. There is no test that:
1. Starts both under the same supervisor
2. Kills and restarts `Kyber.Core`
3. Verifies that LLM responses still work afterward

This is the highest-risk untested scenario.

---

### T4 — Store tests use `async: false` unnecessarily

**File:** `test/kyber_beam/delta/store_test.exs:2`

Each Store test starts its own named Store with a unique temp file (setup block). These are fully isolated. There's no reason for `async: false` here — switching to `async: true` would speed up the test suite with no risk.

---

## Module Boundaries Assessment

| Module | Responsibility | Notes |
|--------|---------------|-------|
| `Kyber.Delta` | Event struct + Origin types | Clean. Pure data. |
| `Kyber.Delta.Store` | Persistence + pub/sub | Good separation, but file I/O in GenServer (see C3). |
| `Kyber.State` | Application state snapshot | Clean Agent wrapper. |
| `Kyber.Reducer` | Pure state transition | Excellent. No side effects. |
| `Kyber.Effect` + `Executor` | Effect struct + async dispatch | Well separated. |
| `Kyber.Core` | Orchestration + supervision | Clean. PipelineWirer pattern is elegant. |
| `Kyber.Session` | Conversation history | Good. ETS ownership issue (H2, M8). |
| `Kyber.Knowledge` | Vault + link graph | Reasonable. Sync load in init (H6). |
| `Kyber.Memory.Consolidator` | Memory pool management | Good concept. O(n) scan risk (M6). |
| `Kyber.ToolExecutor` | Tool dispatch | Large but not a God module. Clean function-per-tool pattern. |
| `Kyber.Cron` | Job scheduling | Good. Serialization concern (M4). |
| `Kyber.Familiard` | External daemon bridge | Good stub with proper webhook validation. |
| `Kyber.Plugin.LLM` | LLM API + tool loop | Doing too much. Tool loop logic could be extracted. |
| `Kyber.Plugin.Discord` | Discord WebSocket + REST | Well structured. Gateway properly separated. |
| `Kyber.Introspection` | BEAM runtime inspection | Clean utility module. |

No circular dependencies detected. No God modules. `Kyber.Plugin.LLM` is the largest single module and could benefit from extracting the tool loop into `Kyber.LLM.ToolLoop` or similar.

---

## Configuration Assessment

| Config | Current | Recommended |
|--------|---------|-------------|
| `vault_path` | `Application.get_env` at startup ✅ | OK |
| `discord_bot_token` | `Application.get_env` at startup ✅ | OK |
| `heartbeat_interval` | `Application.get_env` → Cron opts ✅ | OK |
| `@allowed_write_roots` | Compile-time `Path.expand` ❌ | Runtime function (M3) |
| `@vault_path` in ToolExecutor | Compile-time `Path.expand` ❌ | `Application.get_env` |
| `@missed_threshold_ms` in Cron | Compile-time constant ⚠️ | Opts configurable (L2) |
| `@max_memory_deltas` in Store | Module attr, passable via opts ✅ | OK |
| Auth profile path | Hardcoded `~/.openclaw/agents/main/...` ❌ | `Application.get_env` |

The auth profile path for LLM is hardcoded to OpenClaw's internal path, making the LLM plugin tightly coupled to OpenClaw's deployment layout. This should be configurable.

---

## Priority Summary

| ID | Severity | File | Description |
|----|---------|------|-------------|
| C1 | CRITICAL | application.ex:64 | Unsupervised `spawn` loop |
| C2 | CRITICAL | delta/store.ex:89 | Bare match on File.open crashes init |
| C3 | CRITICAL | delta/store.ex:130 | Blocking disk I/O in handle_call |
| H1 | HIGH | application.ex:58 | `:one_for_one` doesn't protect plugin handler registration after Core restart |
| H2 | HIGH | session.ex:37 | ETS access races with GenServer restart |
| H3 | HIGH | state.ex:90 | Unbounded errors list memory leak |
| H4 | HIGH | plugin/llm.ex:46 | Hardcoded process name, can't be managed by Plugin.Manager |
| H5 | HIGH | delta/store.ex:172 | terminate/2 logs :error on normal shutdown |
| H6 | HIGH | knowledge.ex | Synchronous vault load in init/1 blocks supervisor tree |
| M1 | MEDIUM | state.ex, session.ex | O(n) list concatenation |
| M2 | MEDIUM | application.ex | LLM/Discord plugins bypass Plugin.Manager |
| M3 | MEDIUM | tool_executor.ex:25 | Compile-time path expansion for security boundaries |
| M4 | MEDIUM | cron.ex | 1Hz tick synchronous call chain |
| M5 | MEDIUM | effect.ex | Hardcoded @known_effect_types |
| M6 | MEDIUM | memory/consolidator.ex | O(n) ETS scan |
| M7 | MEDIUM | application.ex:56 | Cryptic Distribution comment |
| M8 | MEDIUM | session.ex:70 | ETS table `:public` allows write bypass |
| T1 | HIGH | core_test.exs, etc. | `Process.sleep` for async coordination |
| T2 | HIGH | knowledge_test.exs | async: true + sleep for file watcher |
| T3 | HIGH | (no file) | No integration test for Core restart + handler re-registration |
| T4 | LOW | delta/store_test.exs | async: false unnecessarily |
| L1 | LOW | application.ex | KyberBeam vs Kyber namespace |
| L2 | LOW | cron.ex | @missed_threshold_ms not configurable |
| L3 | LOW | familiard.ex | Silent context discard on validation failure |
| L4 | LOW | tools.ex | Static tool list not reflecting runtime capability |
| L5 | LOW | delta.ex | Catch-all Origin.deserialize loses type info |
| L6 | LOW | knowledge.ex | Incomplete YAML frontmatter serializer |

---

## What's Working Well

These patterns are genuinely good and worth preserving:

- **`PipelineWirer` as last supervisor child** — elegant solution to "subscribe after all children are started" without any `Process.sleep` hacks. Shows real OTP maturity.
- **`:rest_for_one` in `Kyber.Core`** — correct strategy choice. If Store crashes, stale subscriptions can't exist because all downstream children restart.
- **`Kyber.Reducer` as a pure function** — no process calls, no side effects. Fully testable in isolation. This is the right pattern for state machines in OTP.
- **`Delta.Store` broadcast via `Task.Supervisor`** — subscriber crashes can't crash the Store. Correct isolation.
- **`Delta.Origin` tagged tuple + serialization** — clean, explicit, round-trip safe.
- **`Kyber.Introspection`** — the BEAM introspection module is thoughtful and useful. Good use of `:erlang` BIFs without exposing raw PIDs in output.
- **`broadcast_only` for ephemeral deltas** — the `cron.fired` optimization (skip JSONL persistence) solves a real operational problem cleanly.
- **`@impl true` on all callbacks** — consistent. Makes compiler warnings catch missing callbacks.
- **`@spec` annotations** — good coverage throughout. Helps dialyzer and documentation.

---

*Audit complete. No changes made. All findings are recommendations only.*
