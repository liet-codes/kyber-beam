# Kyber BEAM Phase 2 Code Review

**Reviewer:** Staff Engineer (Kimi subagent)  
**Date:** 2026-03-18  
**Scope:** Phase 2 additions only (Distribution, Deployment, Exo plugin, LiveView dashboard, config, supervision tree)  
**Test Status:** ✅ All 207 tests pass

---

## CRITICAL

*No critical issues found.*

---

## HIGH

### 1. `Distribution` — `seen_delta_ids` MapSet is unbounded memory growth
**File:** `lib/kyber_beam/distribution.ex`  
**Line:** State field `seen_delta_ids: MapSet.new()`  
**Issue:** The deduplication set grows indefinitely as new delta IDs are added. In a long-running cluster with high delta volume, this will cause memory exhaustion.  
**Evidence:** 
```elixir
# In handle_call {:receive_remote_delta, delta}:
seen = MapSet.put(state.seen_delta_ids, delta.id)
# No eviction/reaping logic exists
```
**Recommendation:** Implement a bounded LRU cache or TTL-based eviction. Consider using `:ets` with a size limit or a circular buffer approach.

---

### 2. `Distribution` — Race condition in `sync_missed_deltas`
**File:** `lib/kyber_beam/distribution.ex`  
**Line:** `sync_missed_deltas/3` function  
**Issue:** The function queries remote deltas and calls `GenServer.call(__MODULE__, {:receive_remote_delta, delta})` for each. If the remote node is slow or returns many deltas, this blocks the Distribution GenServer for an unbounded time.  
**Evidence:**
```elixir
Enum.each(remote_deltas, fn delta ->
  GenServer.call(__MODULE__, {:receive_remote_delta, delta})  # Blocking call in loop
end)
```
**Recommendation:** Use `GenServer.cast` for applying synced deltas, or spawn a Task to handle the sync asynchronously. Add timeout protection.

---

### 3. `Deployment` — Git operations block GenServer for extended periods
**File:** `lib/kyber_beam/deployment.ex`  
**Line:** `handle_call({:deploy, git_ref}, ...)`  
**Issue:** The `deploy/2` function runs `git fetch`, `git checkout`, and `mix compile` inside a GenServer call. These can take minutes and will block all other Deployment operations.  
**Evidence:**
```elixir
def handle_call({:deploy, git_ref}, _from, state) do
  with :ok <- git_fetch_and_checkout(git_ref, state.project_dir),
       {:ok, changed_modules} <- mix_compile(state.project_dir),  # Minutes of blocking
```
**Recommendation:** Use `GenServer.cast` + async Task pattern, or implement a job queue. Return `{:noreply, ...}` immediately and notify completion via message or PubSub.

---

## MEDIUM

### 4. `Distribution` — No backpressure on delta broadcast
**File:** `lib/kyber_beam/distribution.ex`  
**Line:** `handle_cast({:broadcast_delta, delta}, state)`  
**Issue:** Deltas are broadcast via `:erpc.cast` to all connected nodes without any rate limiting or backpressure. A burst of local deltas could overwhelm remote nodes.  
**Recommendation:** Consider adding a rate limiter or batching mechanism. Monitor mailbox sizes via `:erlang.process_info/2`.

---

### 5. `Distribution` — `sync_missed_deltas` rescue clause catches all exceptions
**File:** `lib/kyber_beam/distribution.ex`  
**Line:** ~line 248  
**Issue:** The `rescue` block catches all exceptions and only logs a warning, masking potential bugs or systemic issues.  
**Evidence:**
```elixir
rescue
  e ->
    Logger.warning("[Kyber.Distribution] sync failed for #{remote_node}: #{inspect(e)}")
end
```
**Recommendation:** Distinguish between expected failures (timeout, nodedown) and unexpected errors. Consider incrementing a telemetry counter for observability.

---

### 6. `Deployment` — `reload_cluster/2` uses 30s timeout but `:erpc.multicall` has 15s
**File:** `lib/kyber_beam/deployment.ex`  
**Line:** `GenServer.call(server, {:reload_cluster, module}, 30_000)`  
**Issue:** The GenServer call timeout is 30s, but the internal `:erpc.multicall` timeout is 15s. This mismatch is confusing and wastes 15s of wait time if the multicall times out.  
**Recommendation:** Align timeouts or document the intentional difference.

---

### 7. `Endpoint` — `check_origin: false` in dev config is overly permissive
**File:** `config/dev.exs`  
**Issue:** While appropriate for development, this should have a prominent comment warning about production implications.  
**Recommendation:** Add a comment like `# WARNING: Never use check_origin: false in production`.

---

### 8. `DashboardLive` — No authentication on dashboard
**File:** `lib/kyber_beam/web/live/dashboard_live.ex`  
**Issue:** The dashboard exposes system internals (delta counts, node names, plugin list, errors) without any authentication.  
**Recommendation:** Add at least basic auth or IP restriction for production deployments. Document this as a known limitation.

---

### 9. `DashboardLive` — `store_pid/0` relies on process dictionary
**File:** `lib/kyber_beam/web/live/dashboard_live.ex`  
**Line:** `Process.get(:kyber_store_pid) || Kyber.Delta.Store`  
**Issue:** Using process dictionary for test injection is a code smell. It makes the code harder to reason about and can cause issues with process pooling.  
**Recommendation:** Pass the store as an assign during mount, or use a registry lookup.

---

### 10. `Distribution` — `auto_nodes` connection failures are silent
**File:** `lib/kyber_beam/distribution.ex`  
**Line:** `handle_continue(:subscribe, state)`  
**Issue:** Auto-connect failures during init are logged but don't prevent startup or retry. Nodes configured in `auto_nodes` that are temporarily down at boot will never be retried.  
**Recommendation:** Implement a retry backoff for auto_nodes, or expose connection status for health checks.

---

## LOW

### 11. `Exo` plugin — No circuit breaker for failed health checks
**File:** `lib/kyber_beam/plugin/exo.ex`  
**Issue:** If exo is down, every status check will attempt an HTTP connection. No exponential backoff or circuit breaker pattern.  
**Recommendation:** Track consecutive failures and back off polling interval, or implement a simple circuit breaker.

---

### 12. `Exo` plugin — `@poll_interval_ms` is not configurable
**File:** `lib/kyber_beam/plugin/exo.ex`  
**Line:** `@poll_interval_ms 30_000`  
**Issue:** Hardcoded polling interval. Users may want different intervals based on their cluster dynamics.  
**Recommendation:** Make this a config option passed via `opts`.

---

### 13. `Distribution` — `:net_kernel.monitor_nodes(true)` called unconditionally
**File:** `lib/kyber_beam/distribution.ex`  
**Line:** `init/1`  
**Issue:** If the Distribution process crashes and restarts, `monitor_nodes(true)` is called again. While idempotent, this is unnecessary noise.  
**Recommendation:** Consider checking if already monitoring, or document the idempotency.

---

### 14. `Deployment` — `deployed_versions` list has magic number 99
**File:** `lib/kyber_beam/deployment.ex`  
**Line:** `Enum.take(state.deployed, 99)`  
**Issue:** The cap of 100 versions is arbitrary and not documented.  
**Recommendation:** Make this a module attribute with a descriptive name like `@max_version_history`.

---

### 15. `DashboardLive` — `format_ts/1` uses relative time that becomes stale
**File:** `lib/kyber_beam/web/live/dashboard_live.ex`  
**Line:** `format_ts/1` function  
**Issue:** Timestamps are formatted as "5m ago" at render time but don't update until the next refresh.  
**Recommendation:** Either use LiveView's `phx-update` with time-based re-rendering, or display absolute timestamps.

---

### 16. `Endpoint` — `secret_key_base` in config.exs uses hardcoded dev value
**File:** `config/config.exs`  
**Line:** `secret_key_base: "kyber_beam_secret_key_base_at_least_64_chars_long_for_security_dev"`  
**Issue:** While prod.exs overrides this, the dev value is checked into git and could be accidentally used.  
**Recommendation:** Generate a random key on first boot for dev, or use `System.get_env` with a fallback that logs a warning.

---

## Test Coverage Gaps

### 17. `Distribution` — No test for `sync_missed_deltas` success path
**File:** `test/kyber_beam/distribution_test.exs`  
**Issue:** The sync logic that queries remote deltas and applies them is not tested. The `:nodeup` handler path is only tested for "unknown node" case.  
**Recommendation:** Add a test with a mock remote node (using `:erpc` mocking or a local GenServer) to verify sync behavior.

---

### 18. `Distribution` — No test for delta broadcast to multiple nodes
**File:** `test/kyber_beam/distribution_test.exs`  
**Issue:** The broadcast logic is only tested for "no-op when no nodes" and "skips re-broadcasting remote deltas".  
**Recommendation:** Add an integration test with actual connected nodes (using `:slave` or distributed Erlang) or mock the `:erpc.cast` calls.

---

### 19. `Deployment` — No test for `deploy/2` success path
**File:** `test/kyber_beam/deployment_test.exs`  
**Issue:** Only the failure case for nonexistent git ref is tested.  
**Recommendation:** Add a test that deploys a known good ref (e.g., "HEAD") and verifies modules are reloaded. Use a temp git repo if needed.

---

### 20. `Deployment` — No test for `reload_cluster/2` with actual remote nodes
**File:** `test/kyber_beam/deployment_test.exs`  
**Issue:** The test only verifies local reload when no remote nodes are connected.  
**Recommendation:** Add a test with mock remote nodes to verify `:erpc.multicall` behavior.

---

### 21. `DashboardLive` — No LiveView tests
**File:** `test/kyber_beam/web/`  
**Issue:** No `dashboard_live_test.exs` exists. The LiveView mount, events, and rendering are untested.  
**Recommendation:** Add LiveView tests using `Phoenix.LiveViewTest` to verify mount assigns, handle_info callbacks, and rendered content.

---

## Positive Observations

1. **Good use of `handle_continue`** in `Distribution.init/1` to subscribe after GenServer startup
2. **Proper cleanup** with `unsubscribe_fn` stored in state for graceful shutdown
3. **Defensive programming** in `DashboardLive` with `try/rescue` blocks for store queries
4. **Clean separation** of Phoenix endpoint from existing Plug API server
5. **Good test coverage** for Exo plugin edge cases (malformed JSON, empty models, etc.)
6. **Proper CSRF protection** enabled in Phoenix router pipeline

---

## Summary

| Category | Count |
|----------|-------|
| CRITICAL | 0 |
| HIGH | 3 |
| MEDIUM | 7 |
| LOW | 6 |
| Test Gaps | 5 |

The Phase 2 code is generally well-structured and follows OTP conventions. The main concerns are around **unbounded memory growth** (HIGH-1), **blocking operations in GenServer calls** (HIGH-2, HIGH-3), and **missing authentication** on the dashboard (MEDIUM-8). Addressing the HIGH issues should be prioritized before production deployment.
