# Kyber BEAM Code Review

**Reviewer:** Staff Engineer Review (Kimi)  
**Date:** 2026-03-18  
**Scope:** All source files in `lib/`, test coverage analysis, OTP best practices  
**Test Status:** ✅ All 160 tests pass

---

## Executive Summary

Kyber BEAM is a well-architected personal agent harness with delta-driven unidirectional dataflow. The codebase demonstrates solid OTP fundamentals, clean separation of concerns, and good test coverage. However, there are several architectural and correctness issues that should be addressed before production use.

**Overall Assessment:** Early-stage but promising. Core patterns are sound, but supervision, error handling, and race condition protection need attention.

---

## 1. CRITICAL — Must Fix

### 1.1 Race Condition in Delta.Store.subscribe/2 — Unmonitored Tasks
**File:** `lib/kyber_beam/delta/store.ex` (lines 107-110)

**Problem:** The `broadcast/2` function spawns tasks to deliver messages to subscribers without monitoring them:

```elixir
defp broadcast(%{subs: subs}, delta) do
  Enum.each(subs, fn {_id, callback_fn} ->
    Task.start(fn -> callback_fn.(delta) end)
  end)
end
```

**Why it matters:**
- If a subscriber callback crashes, the Task dies silently (no logging, no recovery)
- A misbehaving subscriber can cause memory leaks (unlinked processes)
- No backpressure — slow subscribers don't block the Store but also don't signal overload
- The `Task.start/1` function creates unlinked processes that don't report failures

**Suggested fix:**
```elixir
defp broadcast(%{subs: subs}, delta) do
  Enum.each(subs, fn {_id, callback_fn} ->
    Task.Supervisor.start_child(Kyber.BroadcastTaskSupervisor, fn ->
      try do
        callback_fn.(delta)
      rescue
        e ->
          Logger.error("[Kyber.Delta.Store] subscriber callback crashed: #{inspect(e)}")
          :ok
      end
    end)
  end)
end
```

Or use a dedicated `Task.Supervisor` with `:temporary` restart strategy and monitor for crashes.

---

### 1.2 Kyber.Core.subscribe_reducer/4 — Race Condition on Startup
**File:** `lib/kyber_beam/core.ex` (lines 103-106)

**Problem:** The subscription wiring uses a 50ms sleep and unlinked Task:

```elixir
Task.start(fn ->
  Process.sleep(50)
  subscribe_reducer(core_name, store, state, executor)
  ...
end)
```

**Why it matters:**
- No guarantee children are ready after 50ms (especially under load)
- If the Task crashes during subscription setup, the pipeline never wires
- No retry mechanism — a transient failure leaves the core non-functional
- The test output shows this race: `Task #PID<0.682.0> started from :core_test_1419030 terminating` — GenServer call to non-existent Store

**Suggested fix:** Use a proper initialization handshake:

```elixir
def init(opts) do
  # ... children setup ...
  
  # Return {:ok, state, {:continue, :wire_pipeline}} instead of spawning
  Supervisor.init(children, strategy: :one_for_one)
end

# Then in a GenServer that manages the wiring:
def handle_continue(:wire_pipeline, state) do
  case wait_for_children([store, state_pid, executor], _retries = 10) do
    :ok ->
      subscribe_reducer(...)
      {:noreply, state}
    {:error, missing} ->
      Logger.error("[Kyber.Core] failed to start: #{inspect(missing)} not ready")
      {:stop, :initialization_failed, state}
  end
end

defp wait_for_children(names, retries) do
  # Poll with Process.whereis/1, exponential backoff
end
```

---

### 1.3 Kyber.Session — ETS Table Ownership Risk
**File:** `lib/kyber_beam/session.ex` (lines 78-82)

**Problem:** The ETS table is created with `:public` but owned by the GenServer:

```elixir
def terminate(reason, state) do
  Logger.info("[Kyber.Session] terminating: #{inspect(reason)}")
  :ets.delete(state.table)
  :ok
end
```

**Why it matters:**
- If the GenServer crashes (not graceful terminate), the ETS table is orphaned
- `:public` tables survive owner death only if `:heir` is set or another process monitors
- Concurrent reads during a crash could get `:badarg` errors

**Suggested fix:** Either:
1. Use `:heir` option to transfer ownership on death:
   ```elixir
   :ets.new(table, [:named_table, :public, :set, read_concurrency: true, 
     heir: Process.whereis(Kyber.Session.Heir)])
   ```

2. Or use `persistent_term` for truly global data (if read-heavy, rarely updated)

3. Or don't use `:named_table` and pass the table reference explicitly (safer)

---

### 1.4 Kyber.Plugin.Discord — Token Exposure in Logs
**File:** `lib/kyber_beam/plugin/discord.ex` (lines 243-250)

**Problem:** The `build_identify/1` function embeds the raw token in the payload, and while the code doesn't log it, the `send_ws/2` helper sends it to an external process:

```elixir
defp send_ws(ws_pid, data) when is_pid(ws_pid) do
  send(ws_pid, {:send, data})  # data contains unencrypted token
end
```

**Why it matters:**
- If `ws_pid` is misconfigured or logged, the bot token leaks
- Discord bot tokens are credentials — exposure requires token reset

**Suggested fix:**
- Document that `ws_pid` must be trusted
- Consider using `inspect/2` with `:limit` when logging any state
- Add `@dialyzer` specs to ensure token is always treated as sensitive

---

## 2. HIGH — Should Fix

### 2.1 Kyber.Core — Missing Child Spec Restart Configuration
**File:** `lib/kyber_beam/core.ex` (lines 88-95)

**Problem:** Children are started without explicit restart strategies:

```elixir
children = [
  {Task.Supervisor, name: task_sup},
  {Kyber.Delta.Store, [name: store, path: store_path]},
  {Kyber.State, [name: state]},
  {Kyber.Effect.Executor, [name: executor, task_supervisor: task_sup]},
  {Kyber.Plugin.Manager, [name: plugin_mgr]}
]
```

**Why it matters:**
- Default restart is `:permanent` — if Store crashes 3 times in 5 seconds, the entire Core supervisor terminates
- This is correct for most children, but `Task.Supervisor` should probably be `:transient` (only restart if abnormal exit)

**Suggested fix:**
```elixir
children = [
  {Task.Supervisor, name: task_sup, restart: :transient},  # Don't restart on normal shutdown
  {Kyber.Delta.Store, [name: store, path: store_path]},
  {Kyber.State, [name: state]},
  {Kyber.Effect.Executor, [name: executor, task_supervisor: task_sup]},
  {Kyber.Plugin.Manager, [name: plugin_mgr]}
]
```

---

### 2.2 Kyber.Effect.Executor — String.to_existing_atom/1 Risk
**File:** `lib/kyber_beam/effect.ex` (lines 133-136)

**Problem:** Effect type extraction uses `String.to_existing_atom/1`:

```elixir
defp get_type(%{"type" => t}) when is_binary(t), do: String.to_existing_atom(t)
```

**Why it matters:**
- If an effect comes in with a type that hasn't been loaded as an atom yet, this raises `ArgumentError`
- This is a DoS vector — send an effect with type `"nonexistent_atom_#{random}"` and crash the executor

**Suggested fix:**
```elixir
defp get_type(%{"type" => t}) when is_binary(t) do
  try do
    String.to_existing_atom(t)
  rescue
    ArgumentError -> 
      Logger.warning("[Kyber.Effect.Executor] unknown effect type atom: #{t}")
      :unknown
  end
end
```

---

### 2.3 Kyber.Delta.Store — File I/O in GenServer Call
**File:** `lib/kyber_beam/delta/store.ex` (lines 85-89)

**Problem:** `append/2` does synchronous file write inside `handle_call`:

```elixir
def handle_call({:append, delta}, _from, state) do
  :ok = write_line(state.path, delta)  # blocking disk I/O
  state = %{state | deltas: state.deltas ++ [delta]}
  broadcast(state, delta)
  {:reply, :ok, state}
```

**Why it matters:**
- Disk I/O blocks the GenServer — no queries or appends can proceed
- Under high load, this creates a bottleneck
- If the disk is slow (network mount, degraded SSD), the whole system stalls

**Suggested fix:** Use `cast` + `continue` or a separate writer process:

```elixir
# Option 1: GenServer.continue (Elixir 1.11+)
def handle_call({:append, delta}, _from, state) do
  state = %{state | deltas: state.deltas ++ [delta], pending_write: delta}
  broadcast(state, delta)
  {:reply, :ok, state, {:continue, :persist}}
end

def handle_continue(:persist, %{pending_write: delta} = state) do
  write_line(state.path, delta)
  {:noreply, %{state | pending_write: nil}}
end

# Option 2: Dedicated writer GenServer with message queue
```

---

### 2.4 Kyber.Plugin.LLM — No Request Timeout / Circuit Breaker
**File:** `lib/kyber_beam/plugin/llm.ex` (lines 118-132)

**Problem:** `call_api/2` uses `Req.post` without explicit timeout:

```elixir
case Req.post(@anthropic_url, headers: headers, json: body) do
  {:ok, %{status: 200, body: response}} -> {:ok, response}
  ...
end
```

**Why it matters:**
- Default Req timeout is 30 seconds — during an LLM overload, this blocks the effect handler
- No circuit breaker — if Anthropic is down, every message triggers a slow failure
- No retry with backoff — transient 503 errors fail immediately

**Suggested fix:**
```elixir
def call_api(auth_config, params, opts \\ []) do
  timeout = Keyword.get(opts, :timeout, 15_000)
  retries = Keyword.get(opts, :retries, 3)
  
  Req.post(@anthropic_url, 
    headers: headers, 
    json: body,
    receive_timeout: timeout,
    retry: :transient,
    max_retries: retries,
    retry_delay: &exponential_backoff/1
  )
end
```

---

### 2.5 Kyber.Reducer — No Validation of Delta Payloads
**File:** `lib/kyber_beam/reducer.ex`

**Problem:** The reducer assumes well-formed payloads without validation:

```elixir
def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "llm.response"} = delta) do
  content = Map.get(delta.payload, "content", "")
  # What if payload is nil? Or not a map?
```

**Why it matters:**
- Malformed deltas (from disk corruption, bad API clients) crash the reducer
- The `subscribe_reducer` rescue block catches this, but logs are lost and effects are dropped

**Suggested fix:** Add defensive payload validation:

```elixir
def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "llm.response", payload: payload} = delta) 
    when is_map(payload) do
  content = Map.get(payload, "content", "")
  # ...
end

def reduce(state, %Kyber.Delta{kind: kind} = delta) do
  Logger.warning("[Kyber.Reducer] unhandled or malformed delta: #{kind}")
  {state, []}
end
```

---

## 3. MEDIUM — Improve

### 3.1 Kyber.State — Agent is Single-Process Bottleneck
**File:** `lib/kyber_beam/state.ex`

**Problem:** State is stored in an Agent — all reads/writes serialize through one process.

**Why it matters:**
- `get_and_update/2` is atomic, but concurrent reads block on writes
- For a system designed for "fast concurrent reads" (per Session.ETS), this is inconsistent

**Suggested fix:** Consider ETS for state too, or at least benchmark the Agent under load:

```elixir
# Alternative: ETS with read_concurrency, write via GenServer for atomicity
def init(opts) do
  table = :ets.new(Keyword.get(opts, :name, __MODULE__), 
    [:named_table, :public, :set, read_concurrency: true])
  :ets.insert(table, {:state, %__MODULE__{}})
  {:ok, %{table: table}}
end

def get_and_update(pid, fun) do
  GenServer.call(pid, {:get_and_update, fun})  # Only writes serialize
end

def get(pid) do
  table = table_name(pid)
  [{:state, state}] = :ets.lookup(table, :state)
  state  # Reads are concurrent and non-blocking
end
```

---

### 3.2 Kyber.Plugin.Manager — No Plugin Health Checks
**File:** `lib/kyber_beam/plugin/manager.ex`

**Problem:** Plugins can be registered but there's no health monitoring:

```elixir
def list(supervisor_pid) do
  DynamicSupervisor.which_children(supervisor_pid)
  |> Enum.flat_map(fn {_id, pid, _type, [module]} -> ... end)
end
```

**Why it matters:**
- A plugin could be alive but stuck (e.g., WebSocket not reconnecting)
- No way to query "is this plugin actually working?"

**Suggested fix:** Define a `Kyber.Plugin` behaviour with `health_check/0` callback:

```elixir
defmodule Kyber.Plugin do
  @callback name() :: String.t()
  @callback health_check() :: :ok | {:error, term()}
  @optional_callbacks [health_check: 0]
end

# In Manager:
def health_check(supervisor_pid, name) do
  case find_child_pid(supervisor_pid, name) do
    {:ok, pid} -> 
      if function_exported?(module, :health_check, 0) do
        module.health_check()
      else
        :ok  # Assume healthy if not implemented
      end
    :error -> {:error, :not_found}
  end
end
```

---

### 3.3 Kyber.Delta.Store — In-Memory List Growth is Unbounded
**File:** `lib/kyber_beam/delta/store.ex` (line 86)

**Problem:** All deltas are kept in a list in memory:

```elixir
state = %{state | deltas: state.deltas ++ [delta]}
```

**Why it matters:**
- `++` is O(n) — appending becomes slower as the list grows
- Memory usage grows without bound (no pruning/rotation)
- After months of operation, the VM could exhaust RAM

**Suggested fix:** Implement a circular buffer or max-age pruning:

```elixir
@max_deltas_in_memory 10_000
@max_delta_age_ms 86400_000  # 24 hours

defp maybe_prune_deltas(deltas) do
  now = System.system_time(:millisecond)
  
  deltas
  |> Enum.drop_while(&(now - &1.ts > @max_delta_age_ms))
  |> Enum.take(-@max_deltas_in_memory)
end
```

---

### 3.4 Kyber.Web.Router — No Rate Limiting
**File:** `lib/kyber_beam/web/router.ex`

**Problem:** The HTTP API has no rate limiting:

```elixir
post "/api/deltas" do
  # Anyone can POST unlimited deltas
end
```

**Why it matters:**
- Easy DoS vector — flood with deltas to exhaust disk/memory
- No authentication on the API

**Suggested fix:** Add Plug-based rate limiting:

```elixir
plug PlugAttack, 
  storage: {PlugAttack.Storage.Ets, clean_period: 60_000},
  block_action: :disconnect,
  allow_action: :continue

def allow?(conn, :throttle_deltas, _opts) do
  case conn.method do
    "POST" -> 
      key = conn.remote_ip
      case PlugAttack.Storage.get({key, :delta_count}) do
        nil -> {:allow, 1, [{:delta_count, key, 1, 60_000}]}
        count when count < 100 -> {:allow, count + 1, [{:delta_count, key, count + 1, 60_000}]}
        _ -> {:block, nil, []}
      end
    _ -> {:allow, nil, []}
  end
end
```

---

### 3.5 Kyber.Plugin.Discord — WebSocket Connection Not Implemented
**File:** `lib/kyber_beam/plugin/discord.ex` (lines 131-133)

**Problem:** The WebSocket connection is stubbed:

```elixir
def handle_info(:connect, state) do
  Logger.info("[Kyber.Plugin.Discord] connecting to gateway...")
  # In a real implementation, we'd use a WebSocket client library here.
  {:noreply, state}
end
```

**Why it matters:**
- The plugin claims to connect to Discord Gateway but doesn't
- This is technical debt that should be documented or implemented

**Suggested fix:** Either:
1. Implement using `websockex` or `gun` + `websock`
2. Or rename to `Discord.RestPlugin` and document the limitation
3. Or add a compile-time warning: `@on_load :warn_if_ws_not_implemented`

---

## 4. LOW — Nice to Have

### 4.1 Dead Code — Unused Module Attributes
**File:** `lib/kyber_beam/delta/store.ex` (line 16)

```elixir
@registry Kyber.Delta.Store.Registry  # Never used
```

**File:** `lib/kyber_beam/plugin/discord.ex` (line 27)

```elixir
@gateway_url "wss://gateway.discord.gg/?v=10&encoding=json"  # Referenced in comments only
```

**Fix:** Remove or use these attributes.

---

### 4.2 Deprecated Mix Config Warning
**File:** `mix.exs`

```
warning: setting :preferred_cli_env in your project "def project" is deprecated
```

**Fix:** Move to `def cli` as suggested.

---

### 4.3 Test Warnings — Unused Match
**File:** `test/kyber_beam/plugin/discord_test.exs` (line 162)

```elixir
# This clause never matches because origin has type {:system, binary()}
{:channel, "discord", cid, _} -> cid
```

**Fix:** Remove the dead code or fix the test intent.

---

### 4.4 Missing @spec on Public Functions
**Files:** Various

Several public functions lack `@spec`:
- `Kyber.CLI.parse_args/1`
- `Kyber.CLI.format_delta/1`
- `Kyber.Plugin.Discord.build_message_delta/1`

**Fix:** Add `@spec` for dialyzer and documentation.

---

### 4.5 Kyber.Reducer — Extensibility Pattern
**File:** `lib/kyber_beam/reducer.ex`

The reducer uses hardcoded pattern matching. For a plugin system, consider a registry pattern:

```elixir
def reduce(state, delta) do
  case Registry.lookup(Kyber.Reducer.Registry, delta.kind) do
    [{_pid, handler}] -> handler.(state, delta)
    [] -> {state, []}  # Default: no-op
  end
end
```

This would allow plugins to register their own reducers.

---

## Summary Table

| Severity | Count | Categories |
|----------|-------|------------|
| CRITICAL | 4 | Race conditions, crash isolation, token exposure |
| HIGH | 5 | OTP anti-patterns, DoS vectors, I/O blocking |
| MEDIUM | 5 | API design, resource limits, monitoring |
| LOW | 5 | Code quality, warnings, documentation |

## Recommendations Priority

1. **Immediate (before any production use):**
   - Fix CRITICAL #1 (unmonitored broadcast tasks)
   - Fix CRITICAL #2 (startup race condition)
   - Fix HIGH #2 (atom DoS vector)

2. **Short-term (next sprint):**
   - Fix CRITICAL #3 (ETS ownership)
   - Fix HIGH #1 (restart strategies)
   - Fix HIGH #3 (file I/O blocking)
   - Fix MEDIUM #3 (unbounded memory growth)

3. **Medium-term:**
   - All remaining HIGH and MEDIUM items
   - Add property-based tests (StreamData) for reducer
   - Add chaos testing (simulate crashes, network partitions)

---

*Review completed. All findings are based on static analysis and test observation. No runtime profiling was performed.*
