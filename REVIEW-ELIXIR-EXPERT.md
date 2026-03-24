# Elixir/OTP Expert Code Review — kyber-beam
**Reviewer:** AI Expert (Claude)  
**Date:** 2026-03-23  
**Scope:** lib/ (~11.5K LOC, 40 files), test/ (28 files), config/  

---

## Executive Summary

kyber-beam is a thoughtfully architected LLM agent harness built on the BEAM. The core event-sourcing pattern — immutable deltas flowing through a pure Reducer into supervised Effects — is idiomatic and well-suited to OTP. The supervision tree is intentionally designed (`:rest_for_one` in Kyber.Core, PipelineWirer-as-last-child to eliminate sleep hacks, supervised broadcast Tasks for fault isolation), and the documentation quality is genuinely excellent. The codebase shows real understanding of OTP tradeoffs. That said, a handful of issues deserve attention before this is treated as production-grade: an O(n) append hot-path in Session that will degrade under load, a `BearerAuth` plug that exists but is **never wired into the router**, a few race conditions in the re-registration path, and some architectural drift between `Kyber.Effect` (defined struct) and what the Reducer actually produces (plain maps).

---

## Strengths

### 1. Event-Sourcing Architecture
The Delta → Reducer → Effect pipeline is clean. `Kyber.Reducer.reduce/2` is genuinely pure (no process calls, no side effects), which makes it trivially testable and safe to reason about. The `reducer_test.exs` confirms this with `"reducer is pure — no side effects between calls"`.

### 2. Supervision Tree Design
`Kyber.Core` using `:rest_for_one` is exactly right. If `Delta.Store` crashes, `State`, `Effect.Executor`, `Plugin.Manager`, and `PipelineWirer` all restart in order, preventing stale subscriptions. This is non-obvious and shows genuine OTP mastery.

```elixir
# core.ex
Supervisor.init(children, strategy: :rest_for_one, max_restarts: 10, max_seconds: 30)
```

### 3. PipelineWirer — Eliminates Sleep Hacks
Starting `PipelineWirer` as the last child is an elegant solution to "when are siblings ready?" The supervisor guarantees all prior siblings are started when `init/1` runs, so `Delta.Store.subscribe/2` is called exactly once at the right time with no `Process.sleep`. The comment in the code even explains why. This is exemplary OTP.

### 4. `handle_continue` for Deferred Init
Both `Delta.Store` and `Kyber.Knowledge` defer their disk I/O to `handle_continue`, keeping `init/1` fast and the supervisor unblocked. Correct pattern.

### 5. ETS + GenServer Hybrid in Session
`:protected` ETS with `read_concurrency: true` for `get_history` (hot path, no GenServer round-trip) while writes go through `handle_call` for ordering guarantees. Well-considered.

### 6. Ephemeral Delta Filtering
Routing `cron.fired` through `broadcast_only` instead of `append` (core.ex, ~line 50) prevents the 400K+ disk entries mentioned in the comment. The comment even cites the real incident. Good operational awareness.

### 7. Security Awareness
- SSRF guard in `ToolExecutor.ssrf_safe?/1` covers IPv6 (`::1`), AWS metadata endpoint, `169.254.x.x`
- Exec allowlist (`@allowed_exec_commands`) blocks arbitrary shell injection
- `system` field stripped from `message.received` payloads in the Reducer (M-3 Security Audit note)
- `validate_snowflake/1` for Discord IDs before `delete_message`
- Delta store file permissions set to `0o600` on open
- `send_file` restricted to `allowed_file_send_roots/0`

### 8. Documentation Quality
Every module has clear `@moduledoc`, public API has `@spec`, and the data-flow diagram in `core.ex` is invaluable. Comments explain *why*, not just *what*.

### 9. Test Coverage — Core Flows
Session rehydration tests are comprehensive (32 cases). Reducer tests cover all delta kinds. The LLM restart test (`plugin_llm_restart_test.exs`) documents the re-registration problem explicitly. `async: true` is used where safe.

### 10. Bounded Error Lists in State
```elixir
@max_errors 100
defp add_error(%__MODULE__{} = state, error) do
  trimmed = Enum.take(state.errors ++ [error], -@max_errors)
```
Capping errors at 100 prevents unbounded memory growth. Small but correct.

---

## Critical Issues

### C1. **O(n) Session History Growth** — `session.ex` ~line 110
```elixir
def handle_call({:add_message, chat_id, delta}, _from, %{table: table} = state) do
  history = case :ets.lookup(table, chat_id) do
    [{^chat_id, existing}] -> existing
    [] -> []
  end
  :ets.insert(table, {chat_id, history ++ [delta]})
```
`history ++ [delta]` is O(n) for every message added. For a 1000-message conversation, this does 1000 copy operations. Worse: the entire list is read from ETS, appended to, then written back — so ETS is also doing an O(n) copy. This will degrade perceptibly at ~200 messages/session.

**Fix:** Store reversed (`[delta | history]`) and reverse on read in `get_history/2`. Or enforce a max at write time (the 20-message LLM cap only applies at call time, not at storage).

```elixir
# Fast write: O(1)
:ets.insert(table, {chat_id, [delta | history]})

# Fast enough read: O(n) but n is capped
def get_history(pid, chat_id) do
  # ...existing ETS lookup...
  |> Enum.reverse()
```

### C2. **BearerAuth Plug Is Never Applied** — `web/router.ex` + `web/plugs/bearer_auth.ex`
`Kyber.Web.Plugs.BearerAuth` exists and is well-implemented, but it is **never plugged into `Kyber.Web.Router`**. The `POST /api/deltas` and `GET /api/deltas` endpoints are fully unauthenticated.

```elixir
# web/router.ex — the plug pipeline
plug(Plug.Logger)
plug(:match)
plug(Plug.Parsers, ...)  # ← BearerAuth never appears here
plug(:dispatch)
```

Anyone who can reach port 4000 (or 4001 for Phoenix) can inject arbitrary deltas. Since deltas drive the Reducer and can trigger LLM calls, this is a real security issue.

**Fix:**
```elixir
plug(Plug.Logger)
plug(:match)
plug(Plug.Parsers, parsers: [:json], json_decoder: Jason)
plug(Kyber.Web.Plugs.BearerAuth)  # ← add this
plug(:dispatch)
```

### C3. **Re-registration Race Condition in Plugin.LLM** — `plugin/llm.ex` ~line 170
The `handle_info(:reregister_after_core_restart, state)` path polls every 500ms until the executor appears:

```elixir
if executor && Process.alive?(executor) do
  state = register_effect_handler(state)
  ...
else
  Process.send_after(self(), :reregister_after_core_restart, 500)
```

There's a window between when the Executor restarts and when LLM re-registers where `llm_call` effects will be silently dropped (`{:error, :no_handler}`). The test at line `plugin_llm_restart_test.exs:77` *documents* this but doesn't assert re-registration actually happens after restart.

More importantly: when Core uses `:rest_for_one`, the **PipelineWirer also restarts** and re-subscribes to the store. But Plugin.LLM's handler registration with the new Executor still depends on this polling loop succeeding before the next `message.received` event arrives.

**Fix:** Use `Process.monitor/1` on the new Executor PID (from the `:DOWN` restart) and re-register in `handle_info({:DOWN, ...})` for the *new* monitor. Eliminate the polling loop entirely.

### C4. **`POST /api/deltas` Bypasses Core.emit's Ephemeral Filtering** — `web/router.ex` ~line 40
```elixir
post "/api/deltas" do
  # ...
  :ok = Kyber.Delta.Store.append(store, delta)
```
This bypasses `Kyber.Core.emit/2` which filters ephemeral delta kinds (e.g., `cron.fired`) via `persist_delta?/1`. An external caller can send `{"kind": "cron.fired"}` and it will be persisted to disk, bloating the JSONL file. Additionally, it skips the safety stripping of the `"system"` key in the Reducer.

**Fix:** Route through `Kyber.Core.emit/2` instead of directly calling `Delta.Store.append/2`.

### C5. **Knowledge Reload Tasks Can Race** — `knowledge.ex` ~line 255
```elixir
def handle_info(:poll_vault, state) do
  server = self()
  vault_dir = state.vault_path
  old_mtimes = state.file_mtimes

  Task.start(fn ->
    if File.dir?(vault_dir) do
      result = read_changed_notes(vault_dir, old_mtimes)
      send(server, {:reload_complete, result})
    end
  end)

  schedule_poll(state.poll_interval)
  {:noreply, state}
end
```
There is no guard preventing multiple concurrent reload tasks. If a reload takes more than 5 seconds (slow disk, large vault), the next poll fires while the previous task is still running. Two tasks may send `{:reload_complete, ...}` with different `new_mtimes` maps — the second `handle_info` call will merge its (stale) mtimes over the first, potentially causing files to not be detected as changed on the next poll.

**Fix:** Track a `reload_task_ref` in state, similar to how `Memory.Consolidator` tracks `scoring_in_progress`. Ignore `:poll_vault` when a reload is already running.

---

## Recommendations

### R1. `Kyber.Effect` Struct vs. Plain Maps — `effect.ex` / `reducer.ex`
`Kyber.Effect` is defined as:
```elixir
defstruct type: nil, data: %{}
```
But `Kyber.Reducer` produces plain maps:
```elixir
%{type: :llm_call, delta_id: delta.id, payload: safe_payload, origin: delta.origin}
```
The `Kyber.Effect` struct's `data` field is never used; the actual fields are `delta_id`, `payload`, and `origin`. The struct exists but provides no value. `Effect.Executor.get_type/1` handles both forms with `get_type(%Kyber.Effect{type: t})` and `get_type(%{type: t})`.

**Recommendation:** Either delete `Kyber.Effect` (the struct) and document that effects are plain maps with `type` + context keys, or migrate all effect production to actually use `%Kyber.Effect{type: ..., data: %{delta_id: ..., payload: ...}}`.

### R2. `trim_memory/2` Uses `length/1` on Every Append — `delta/store.ex` ~line 165
```elixir
defp trim_memory(deltas, max) when length(deltas) > max do
  Enum.take(deltas, -max)
end
```
`length/1` on a list is O(n). This runs on every `handle_call({:append, ...})`. With 10,000 entries, that's 10,000 operations per append call, every call. Track `delta_count` separately in state.

```elixir
# In state:  %{deltas: [...], delta_count: 0}
# On append:
{new_deltas, new_count} =
  if state.delta_count >= state.max_memory_deltas do
    trimmed = Enum.take(state.deltas ++ [delta], -state.max_memory_deltas)
    {trimmed, state.max_memory_deltas}
  else
    {state.deltas ++ [delta], state.delta_count + 1}
  end
```

### R3. `process_alive?` Guard in Plugin.LLM is TOCTOU — `plugin/llm.ex`
```elixir
if chat_id && process_alive?(session) do
  Kyber.Session.add_message(session, chat_id, user_delta)
end
```
The session could die between `process_alive?/1` and `add_message/3`. Since this runs in a supervised Task, the process death will produce an exit signal or `{:EXIT, ...}` message, not a crash. Prefer:
```elixir
try do
  Kyber.Session.add_message(session, chat_id, user_delta)
catch
  :exit, _ -> :ok
end
```

### R4. Cron's `find_match` Can Block GenServer — `cron.ex` ~line 400
```elixir
defp find_match(_fields, dt, limit) when limit > 525_601 do
  # More than a year of minutes — give up
  DateTime.add(dt, 60, :second)
end

defp find_match(fields, dt, limit) do
  # recurse minute-by-minute
  find_match(fields, DateTime.add(dt, 60, :second), limit + 1)
end
```
For a cron expression that matches rarely (e.g., `59 23 31 12 5` — last day of year that's also a Friday), this can recurse through 525,601 iterations **in the Cron GenServer process**. Each `DateTime.add/3` + comparison is cheap, but 525K iterations could still pause the GenServer for hundreds of milliseconds.

**Recommendation:** Run `compute_next_cron/2` in a `Task` if the expression doesn't match within the next 1000 minutes. Or precompute next-run at job registration time and cache it.

### R5. Discord Gateway URL from API Is Ignored — `plugin/discord/gateway.ex` ~line 100
```elixir
defp start_connection(token) do
  _ = fetch_gateway_url(token)  # ← result is discarded!
  case Mint.HTTP.connect(:https, @gateway_host, @gateway_port, ...) do
```
`fetch_gateway_url/1` calls Discord's `/gateway/bot` endpoint which returns the optimal gateway URL for your shard, but the result is ignored. The hardcoded `@gateway_host = "gateway.discord.gg"` is used instead. This is fine for a single-shard bot but will matter if this ever runs across multiple shards.

### R6. `find_by_vault_ref` Does Full ETS Scan Every Scoring Cycle — `memory/consolidator.ex`
```elixir
defp find_by_vault_ref(table, vault_ref) do
  :ets.tab2list(table)
  |> Enum.find_value(fn {_id, mem} ->
    if Map.get(mem, :vault_ref) == vault_ref, do: mem, else: nil
  end)
end
```
Called for every vault path in `merge_vault_scored/4`. If the memory pool has 200 entries and 30 vault notes changed, that's 6,000 ETS reads.

**Fix:** Add a secondary ETS table or use `:ets.match_object/2`:
```elixir
defp find_by_vault_ref(table, vault_ref) do
  case :ets.match_object(table, {:_, %{vault_ref: vault_ref}}) do
    [{_id, mem} | _] -> mem
    [] -> nil
  end
end
```
Or maintain a `vault_ref → id` map in GenServer state.

### R7. `Delta.Store` Disk Query Blocks on Task.yield — `delta/store.ex` ~line 130
```elixir
def handle_call({:query, filters}, _from, state) do
  deltas =
    if needs_disk_fallback?(state.deltas, since) do
      task = Task.async(fn -> load_from_disk(path) end)
      case Task.yield(task, 5_000) || Task.shutdown(task) do
```
`Task.yield/2` inside a `handle_call` blocks the GenServer for up to 5 seconds while awaiting disk I/O. Any other process calling `append`, `subscribe`, or `query` during this window will time out. While using `Task.async` moves the work off the GenServer, `yield` re-blocks it.

**Fix:** Use `handle_continue` or `cast` to trigger async loading; respond to the original caller via a deferred reply with `GenServer.reply/2`.

### R8. Application Starts Session Before Core, But Session Needs Core's Store — `application.ex`
```elixir
children = [
  {Phoenix.PubSub, name: Kyber.PubSub},
  {Kyber.Session, name: Kyber.Session},   # ← started before Core
  {Kyber.Core, name: Kyber.Core},         # ← Core starts here
  ...
```
`Kyber.Session` accepts a `delta_store:` opt for rehydration. The default start (`Kyber.Session`) gets `delta_store: nil` (no rehydration). If someone passes a `delta_store:` explicitly, it would reference a store not yet started. This is confusing but not currently broken.

**Recommendation:** Move `Kyber.Session` after `Kyber.Core` in the children list, and plumb `delta_store: :"Kyber.Core.Store"` so rehydration works automatically.

### R9. `Kyber.Distribution` Started Last But Has No Wait for Core Ready
```elixir
# LAST — subscribes to Core's children
{Kyber.Distribution, name: Kyber.Distribution}
```
`Distribution.init/1` subscribes to the local store and monitors nodes. If the store subscription happens during a brief window where Core is still initializing its `PipelineWirer`, there's potential for deltas emitted during startup to not be replicated. Not a crash-causing bug but worth documenting.

---

## Minor Nits

**N1. `Kyber.Core.PipelineWirer` Co-Located in `core.ex`**  
The `PipelineWirer` module is defined in `core.ex`. For a ~200-line internal module this is fine, but Elixir convention is one module per file. If `PipelineWirer` grows, extract it to `lib/kyber_beam/core/pipeline_wirer.ex`.

**N2. `toggle_job/2` Fallback Clause is Dead Code** — `cron.ex`
```elixir
def handle_call({:toggle_job, name}, _from, state) do
  # Fallback clause — missing enabled arg; default to true
```
No caller sends `{:toggle_job, name}` without an enabled arg. The public API is `toggle_job/3` which always sends `{:toggle_job, name, enabled}`. Remove this clause or add a guard.

**N3. `Kyber.Delta` ID Generation Uses Hex, Not UUID**  
```elixir
defp generate_id do
  :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
end
```
Fine for internal use, but the IDs are 32-char hex strings (no hyphens), which looks like a UUID but isn't. Document this or use a UUID library if you ever need to interop with external systems that validate UUID format.

**N4. `Kyber.Effect.Executor` Monitors Task Refs Unnecessarily**  
```elixir
def handle_info({ref, _result}, state) when is_reference(ref) do
  Process.demonitor(ref, [:flush])
  {:noreply, state}
end
```
`Task.Supervisor.async_nolink/2` does NOT auto-monitor in the calling process — this `handle_info` receives `{ref, result}` only because `Task.async` (not `async_nolink`) links and monitors. With `async_nolink`, these messages arrive only as `{:DOWN, ref, :process, pid, :normal}`. The current code works but is slightly confused about which Task variant it's using.

**N5. `Kyber.Knowledge.serialize_note` Has a Naive YAML Serializer**  
```elixir
defp frontmatter_to_yaml(map) do
  map
  |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{yaml_value(v)}" end)
```
This doesn't handle nested maps, lists of maps, multi-line strings properly, or keys that need quoting. Fine for simple frontmatter, but could corrupt vault files with complex frontmatter.

**N6. `Kyber.Memory.Consolidator` Logs `inspect/1` on Large Data Structures**  
```elixir
Logger.info("[Kyber.Memory.Consolidator] scoring #{length(Enum.uniq(paths))} paths: #{inspect(Enum.uniq(paths))}")
```
`inspect/1` on a list of 50+ paths will emit a very long log line. Use `Enum.join/2` and truncate, or log the count only.

**N7. `Process.sleep` in Integration Tests** — `core_test.exs`
```elixir
test "emit appends a delta to the store" do
  ...
  :ok = Core.emit(name, delta)
  Process.sleep(50)  # ← timing-dependent
```
The code comment says "PipelineWirer wires synchronously... no sleep needed for subscription" but then uses `Process.sleep(50)` for async dispatch latency. This is acceptable but documented confusingly. `assert_receive` with a timeout is more robust:
```elixir
:ok = Core.emit(name, delta)
# Use assert_receive or poll with backoff instead of blind sleep
```

**N8. `Kyber.Web.Router.store_pid` Hardcodes Atom String**
```elixir
defp store_pid do
  Process.get(:kyber_store_pid) || :"Elixir.Kyber.Core.Store"
end
```
`:"Elixir.Kyber.Core.Store"` is `Kyber.Core.Store` expressed as a bare atom string. If the Core is started with a non-default name (e.g., in tests), this will fail. Use `Kyber.Core.store_name/1` (if you expose it) or pass the store name through the Plug's opts.

**N9. Missing Tests for**:
- `POST /api/deltas` (auth bypass described in C2 would be caught immediately)
- `Kyber.Cron` cron expression parsing edge cases
- `Kyber.Plugin.Discord.chunk_message/1` (splitting logic)
- `Kyber.Delta.Store` query with `:since` predating memory window (disk fallback path)

---

## Overall Grade: **B+**

**Justification:** This is genuinely good Elixir/OTP engineering. The supervision design, event-sourcing pattern, pure Reducer, PipelineWirer idiom, and ETS/GenServer hybrid in Session all reflect sound OTP understanding. The documentation is better than most production codebases. The security awareness is real (SSRF, path traversal, exec allowlist).

The grade doesn't reach A because:
1. The `BearerAuth` plug existing but not being wired in is a production-breaking security gap (C2)
2. The O(n) session append will become a real performance problem at scale (C1)
3. The re-registration race condition for LLM after Core restart is unresolved (C3)
4. The Effect struct/plain-map inconsistency creates confusion for contributors (R1)
5. A few integration tests rely on `Process.sleep` rather than proper assertion patterns (N7)

For a personal agent harness, these are acceptable. For a multi-user production deployment, C1 and C2 are blockers.

---

*Review generated by static code analysis of all 40 source files and 28 test files.*
