# Phase 3 Code Review — Kyber BEAM

**Reviewer:** Kimi (subagent)  
**Date:** 2026-03-18  
**Scope:** Phase 3 additions — Knowledge, Voice, Cron, Familiard, Reducer updates, Application supervision tree  
**Test Status:** ✅ All 306 tests pass

---

## CRITICAL

### 1. Knowledge — Race Condition on File I/O (CRON-001)
**File:** `lib/kyber_beam/knowledge.ex`  
**Lines:** 79-97 (`handle_call {:put_note, ...}`), 144-154 (`load_vault/1`)

**Issue:** The GenServer performs blocking file I/O (`File.write/2`, `File.read/1`, `Path.wildcard/2`) inside `handle_call/2` callbacks. This blocks the entire GenServer process for the duration of the operation. During vault reloads (every 5 seconds by default), all concurrent read operations are blocked.

**Impact:**
- High latency on concurrent `get_note/2`, `query_notes/2` calls during vault polling
- Potential for message queue buildup if vault is large
- No backpressure mechanism

**Recommendation:**
```elixir
# Move file I/O to a Task or use :gen_server.cast for writes
# Use ETS for the in-memory cache to allow concurrent reads
# Or use GenServer.call with a timeout and handle {:timeout, _} at callers
```

**Priority:** Fix before production use with large vaults.

---

### 2. Cron — Timer Drift on System Sleep/Time Jumps (CRON-002)
**File:** `lib/kyber_beam/cron.ex`  
**Lines:** 178-182 (`check_and_fire/2`)

**Issue:** The cron scheduler uses `Process.send_after/2` with a fixed 1-second check interval. If the system sleeps or time jumps forward (NTP sync, VM suspend), jobs may be missed or fired late. The `compute_next_run/2` logic compares against `DateTime.utc_now()`, which can jump discontinuously.

**Impact:**
- Missed job executions after system sleep
- Bursts of job firings when time catches up (not handled)

**Recommendation:**
```elixir
# Use :erlang.monotonic_time for scheduling, convert to wall clock only for display
# Or track expected next check time and handle gaps:
missed = div(time_diff, @check_interval_ms)
if missed > 1, Logger.warning("Cron missed #{missed} check intervals")
```

**Priority:** Fix for reliability-critical deployments.

---

### 3. Voice Plugin — API Key Exposure in Process State (SEC-001)
**File:** `lib/kyber_beam/plugin/voice.ex`  
**Lines:** 45-50 (`init/1`), 85 (`handle_call :get_api_key`)

**Issue:** The ElevenLabs API key is stored in plain text in the GenServer state and exposed via a `handle_call(:get_api_key, ...)` callback. While this is used internally for the effect handler, any process can call `GenServer.call(Kyber.Plugin.Voice, :get_api_key)` to retrieve it.

**Impact:**
- API key leakage to any code running in the BEAM
- Potential for unauthorized TTS usage if sandbox is compromised

**Recommendation:**
```elixir
# Remove :get_api_key callback entirely
# Pass api_key directly to call_elevenlabs/4 from init state
# Or use :persistent_term for secrets (still readable but less obvious)
# Better: Use a separate secret manager process with restricted access
```

**Priority:** Fix before any multi-tenant or plugin-based deployment.

---

## HIGH

### 4. Familiard Webhook — Missing HMAC/Signature Validation (SEC-002)
**File:** `lib/kyber_beam/web/familiard_controller.ex`  
**Lines:** 10-28 (`escalate/2`)

**Issue:** The webhook endpoint `/api/familiard/escalate` accepts escalation events without any authentication or signature validation. An attacker with network access can inject fake escalation events.

**Impact:**
- Spurious critical alerts
- Potential for DoS via alert fatigue
- Downstream effects (LLM calls) triggered by forged events

**Recommendation:**
```elixir
# Add HMAC-SHA256 signature validation:
def escalate(conn, params) do
  signature = get_req_header(conn, "x-familiard-signature")
  secret = Application.get_env(:kyber_beam, :familiard_webhook_secret)
  
  if valid_signature?(params, signature, secret) do
    # ... process
  else
    conn |> put_status(401) |> json(%{ok: false, error: "unauthorized"})
  end
end
```

**Priority:** Fix before exposing endpoint to untrusted networks.

---

### 5. Knowledge — No File Change Detection (RACE-003)
**File:** `lib/kyber_beam/knowledge.ex`  
**Lines:** 220-240 (`read_all_notes/2`)

**Issue:** The vault polling reloads ALL notes on every poll interval (5 seconds), even if no files changed. For large vaults, this is O(n) file reads every 5 seconds. There's no mtime/SHA comparison to skip unchanged files.

**Impact:**
- Unnecessary disk I/O
- CPU usage scales with vault size, not change rate
- Potential for note state flicker if read fails mid-reload

**Recommendation:**
```elixir
# Store file mtimes in state, only re-read changed files:
Enum.reduce(md_files, state, fn path, acc ->
  mtime = File.stat!(path).mtime
  if mtime != get_cached_mtime(acc, path) do
    # re-read and update
  else
    acc
  end
end)
```

**Priority:** Fix for vaults >100 notes.

---

### 6. Cron — No Persistence Across Restarts (RELIABILITY-001)
**File:** `lib/kyber_beam/cron.ex`  
**Lines:** 55-68 (`init/1`)

**Issue:** Scheduled jobs are stored only in process state. On application restart, all jobs are lost. One-shot `{:at, datetime}` jobs that were scheduled but not yet fired are silently dropped.

**Impact:**
- Missed reminders after deploy/restart
- No recovery mechanism for critical scheduled tasks

**Recommendation:**
```elixir
# Persist jobs to Delta.Store or ETS with disk backup
# On init, reload jobs from store and recompute next_run
# Mark one-shot jobs as "completed" after firing
```

**Priority:** Fix for production use with user-facing reminders.

---

## MEDIUM

### 7. Knowledge — YAML Serialization Not Round-Trip Safe (BUG-001)
**File:** `lib/kyber_beam/knowledge.ex`  
**Lines:** 252-275 (`serialize_note/2`, `frontmatter_to_yaml/1`)

**Issue:** The custom YAML serializer doesn't handle nested maps, lists of maps, or special characters correctly. The parser uses `YamlElixir` but the serializer is hand-rolled.

**Example:**
```elixir
# This frontmatter:
%{"nested" => %{"key" => "value"}}
# Serializes to:
nested: [object Object]  # or similar garbage
```

**Impact:**
- Data corruption on note save
- Loss of complex frontmatter structures

**Recommendation:**
```elixir
# Use YamlElixir for both read and write:
yaml = YamlElixir.write_to_string(frontmatter)
# Or use a simpler format like TOML with toml_elixir
```

**Priority:** Fix before supporting complex frontmatter.

---

### 8. Voice Plugin — No Retry/Backoff on API Failure (RELIABILITY-002)
**File:** `lib/kyber_beam/plugin/voice.ex`  
**Lines:** 156-177 (`call_elevenlabs/4`)

**Issue:** ElevenLabs API failures return `{:error, reason}` immediately with no retry. Transient network errors or rate limits cause immediate failure.

**Impact:**
- Poor UX for TTS — single network blip fails the request
- No circuit breaker pattern for cascading failures

**Recommendation:**
```elixir
# Add retry with exponential backoff:
Req.post(url, headers: headers, json: body, 
  retry: :transient,
  retry_delay: &Retry.delay/1,
  max_retries: 3
)
```

**Priority:** Nice to have for production TTS usage.

---

### 9. Familiard — No Timeout on HTTP Polling (RELIABILITY-003)
**File:** `lib/kyber_beam/familiard.ex`  
**Lines:** 112-127 (`poll_familiard_status/1`)

**Issue:** The `Req.get/2` call uses `receive_timeout: 5_000` but no `connect_timeout`. A hanging TCP connection could block the GenServer indefinitely.

**Impact:**
- GenServer mailbox buildup if familiard is unresponsive
- Timeout only applies after connection, not during establishment

**Recommendation:**
```elixir
Req.get(health_url, 
  connect_timeout: 3_000,
  receive_timeout: 5_000
)
```

**Priority:** Fix for robustness.

---

### 10. KnowledgeController — String.to_existing_atom/1 Risk (BUG-002)
**File:** `lib/kyber_beam/web/knowledge_controller.ex`  
**Lines:** 15-16

**Issue:** `String.to_existing_atom/1` will raise `ArgumentError` if the atom doesn't exist. The controller catches this with a bare `rescue _ ->` but this masks all errors, not just the atom issue.

**Impact:**
- Silent failures on legitimate errors (e.g., database corruption)
- Hard to debug "why is my query returning empty?"

**Recommendation:**
```elixir
# Use safe atom conversion:
type = params["type"]
if type && type in ~w(memory identity people projects concepts tools decisions) do
  Keyword.put(f, :type, String.to_existing_atom(type))
else
  f
end
```

**Priority:** Fix for better error handling.

---

## LOW

### 11. Reducer — Pattern Match Ordering (STYLE-001)
**File:** `lib/kyber_beam/reducer.ex`  
**Lines:** 85-119

**Issue:** The `familiard.escalation` and `cron.fired` pattern matches are fine, but the catch-all at line 119 could accidentally swallow new delta kinds that should have handlers. Consider using a stricter approach.

**Recommendation:**
```elixir
# Add a warning log for unhandled delta kinds in development:
def reduce(state, %Delta{kind: kind} = delta) do
  if Mix.env() == :dev do
    Logger.warning("Unhandled delta kind: #{kind}")
  end
  {state, []}
end
```

**Priority:** Nice to have for development experience.

---

### 12. Test Coverage Gaps (TEST-001)

**Missing Tests:**

1. **Knowledge polling race condition** — No test for concurrent `put_note` during `load_vault`
2. **Cron timer accuracy** — Tests use 1ms intervals which don't validate real-world timing
3. **Voice effect handler integration** — Tests verify registration but not actual handler execution
4. **Familiard webhook authentication** — No tests for missing/invalid signatures (because feature doesn't exist)
5. **Application supervision restart** — No test for child restart on crash

**Recommendation:** Add property-based tests for cron scheduling and concurrency tests for Knowledge.

---

### 13. Application Supervision — No Restart Intensity Configuration (OTP-001)
**File:** `lib/kyber_beam/application.ex`  
**Lines:** 26-35

**Issue:** The supervisor uses default `max_restarts: 3` and `max_seconds: 5`. For a cron scheduler or knowledge vault, rapid restarts could indicate persistent failure (disk full, corrupt vault).

**Recommendation:**
```elixir
opts = [
  strategy: :one_for_one, 
  name: KyberBeam.Supervisor,
  max_restarts: 5,
  max_seconds: 30
]
```

**Priority:** Low — current defaults are reasonable for development.

---

### 14. Voice Plugin — Hardcoded Default Voice ID (CONFIG-001)
**File:** `lib/kyber_beam/plugin/voice.ex`  
**Line:** 17

**Issue:** The default voice ID `"6OBKYcAOcB3NNsCq3WHx"` is hardcoded. If ElevenLabs deprecates this voice, the plugin will fail for users who haven't configured a custom voice.

**Recommendation:**
```elixir
# Fetch from config with no hardcoded default:
default_voice_id =
  Keyword.get(opts, :default_voice_id) ||
  Keyword.get(app_config, :default_voice_id) ||
  raise "No default_voice_id configured for Kyber.Plugin.Voice"
```

**Priority:** Low — configuration option exists.

---

## Summary Table

| ID | Severity | File | Issue | Fix Effort |
|----|----------|------|-------|------------|
| CRON-001 | CRITICAL | knowledge.ex | Blocking file I/O in GenServer | Medium |
| CRON-002 | CRITICAL | cron.ex | Timer drift on time jumps | Medium |
| SEC-001 | CRITICAL | voice.ex | API key exposure | Low |
| SEC-002 | HIGH | familiard_controller.ex | No webhook auth | Medium |
| RACE-003 | HIGH | knowledge.ex | No file change detection | Medium |
| RELIABILITY-001 | HIGH | cron.ex | No job persistence | Medium |
| BUG-001 | MEDIUM | knowledge.ex | YAML not round-trip safe | Low |
| RELIABILITY-002 | MEDIUM | voice.ex | No retry on API failure | Low |
| RELIABILITY-003 | MEDIUM | familiard.ex | Missing connect timeout | Low |
| BUG-002 | MEDIUM | knowledge_controller.ex | Unsafe atom conversion | Low |
| STYLE-001 | LOW | reducer.ex | Unhandled delta warning | Trivial |
| TEST-001 | LOW | test/ | Coverage gaps | Medium |
| OTP-001 | LOW | application.ex | No restart intensity config | Trivial |
| CONFIG-001 | LOW | voice.ex | Hardcoded voice ID | Trivial |

---

## Positive Findings

1. **Good separation of concerns** — Reducer remains pure, effects are dispatched asynchronously
2. **Proper OTP supervision** — All GenServers are supervised, named processes use `__MODULE__` or configurable names
3. **Test coverage** — 306 tests passing, good unit test coverage for core logic
4. **Error handling** — Most external calls have try/rescue blocks with logging
5. **Config flexibility** — Environment variable fallbacks for API keys, application config support
6. **Graceful degradation** — Voice plugin starts without API key (warning mode), Familiard handles nil core

---

## Recommendations for Phase 3.1

1. **Add a `Kyber.Vault.Watcher` GenServer** using `file_system` library for event-driven vault updates instead of polling
2. **Implement job persistence** in Cron using Delta.Store
3. **Add webhook signature validation** for all external endpoints
4. **Use ETS for Knowledge cache** with GenServer for writes only
5. **Add OpenTelemetry spans** for Voice TTS and Knowledge queries
