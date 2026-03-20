# SECURITY_AUDIT.md — kyber-beam

**Audited by:** Senior Security Engineer (automated sub-agent review)  
**Date:** 2026-03-20  
**Codebase:** `/Users/liet/kyber-beam` — Elixir/OTP agent harness with Discord integration  
**Scope:** Full `lib/` review, config files, and test gap analysis  

---

## Summary

| Severity | Count |
|----------|-------|
| CRITICAL | 4     |
| HIGH     | 6     |
| MEDIUM   | 7     |
| LOW      | 6     |

kyber-beam is a personal tool on a local machine, which meaningfully changes the risk landscape.
However, several issues could allow remote abuse (via Discord messages or the HTTP API), token
leakage, and arbitrary code execution escalation that bypasses the intended trust model.

---

## CRITICAL

---

### C-1: Unrestricted Shell Command Execution via `exec` Tool

**File:** `lib/kyber_beam/tool_executor.ex:122-140`

The `exec` tool passes any LLM-generated shell command directly to `sh -c` with no denylist, no
sandboxing, and no allowlist of permitted commands.

```elixir
def execute("exec", %{"command" => cmd} = input) do
  workdir = Map.get(input, "workdir", System.get_env("HOME", "/tmp"))
  # ...
  System.cmd("sh", ["-c", cmd], cd: expanded_dir, stderr_to_stdout: true)
```

The comment in the code itself acknowledges "no denylist; personal machine." However:

- A crafted Discord message → LLM response chain could induce arbitrary `exec` calls via prompt
  injection (e.g., a Discord user sends a message that tricks the LLM into believing it should
  run a specific shell command as a "tool use").
- The LLM can be prompted via the `"message.received"` → `llm_call` path entirely from Discord
  input, which is partially untrusted.
- `workdir` is path-expanded but **not validated** — an attacker-controlled input could set it to
  any directory including sensitive ones.

**Impact:** Full host compromise via crafted Discord messages exploiting prompt injection.

**Fix:**
- Add a human-approval step or confirmation requirement before `exec` runs (e.g. Discord reaction
  gate: the bot sends the command to the user and requires ✅ before executing).
- Alternatively, restrict to a denylist of dangerous patterns (`rm -rf`, `curl | sh`, network
  exfiltration commands, etc.) and log all executions at WARNING level (already done, good).
- Harden the workdir: validate `expanded_dir` against an allowlist similar to `@allowed_write_roots`.

---

### C-2: `POST /api/deltas` — Unauthenticated Delta Injection

**File:** `lib/kyber_beam/web/router.ex:34-55`

The Plug-based REST API at port 4000 has **no authentication** on any endpoint:

```elixir
post "/api/deltas" do
  body = conn.body_params
  with {:ok, kind} <- Map.fetch(body, "kind") do
    # kind is taken directly from user input with no validation
    delta = Kyber.Delta.new(kind, payload, origin, parent_id)
    :ok = Kyber.Delta.Store.append(store, delta)
```

Any process that can reach port 4000 (which in dev has `check_origin: false`) can:
1. Inject a `"message.received"` delta → triggers an LLM call at the owner's expense.
2. Inject a `"familiard.escalation"` delta with `level: "critical"` → triggers an LLM call with
   arbitrary content in the system.
3. Inject a `"cron.fired"` delta with `job_name: "heartbeat"` → same LLM call trigger.
4. Flood the delta store with garbage data.

**Impact:** Unauthenticated LLM budget exhaustion, prompt injection, delta log pollution.

**Fix:**
- Add an API token check via a `Plug` middleware on the `/api` scope.
- At minimum, bind the Plug server to `127.0.0.1` only (not `0.0.0.0`) in production.
- Validate `kind` against a known allowlist before accepting the delta.

---

### C-3: Familiard Webhook — `verify_signature` Implemented But Never Called

**File:** `lib/kyber_beam/web/familiard_controller.ex:9-26`
**Ref:** `lib/kyber_beam/familiard.ex:59-70`

`Kyber.Familiard` has a complete `verify_signature/3` implementation using HMAC-SHA256 with
constant-time comparison. However, `FamiliardController.escalate/2` **never calls it**:

```elixir
def escalate(conn, params) do
  case Kyber.Familiard.parse_escalation(params) do
    {:ok, event} ->
      # ← NO signature check here
      familiard = familiard_pid()
      if familiard, do: Kyber.Familiard.emit_escalation(familiard, event)
```

Any unauthenticated HTTP client can POST to `/api/familiard/escalate` and inject escalation
events. Combined with the reducer logic that converts `"critical"` escalations into `llm_call`
effects with arbitrary message content, this is a complete prompt injection vector.

**Impact:** Arbitrary prompt injection into LLM pipeline without any authentication.

**Fix:**
```elixir
def escalate(conn, params) do
  signature = get_req_header(conn, "x-familiard-signature") |> List.first()
  raw_body = conn.private[:raw_body] || ""   # requires Plug.Parsers raw_body caching

  familiard = familiard_pid()
  case Kyber.Familiard.verify_signature(familiard, raw_body, signature) do
    :ok -> # proceed
    {:error, :no_secret} -> # dev mode, proceed with warning
    {:error, :invalid_signature} ->
      conn |> put_status(401) |> json(%{ok: false, error: "invalid signature"}) |> halt()
  end
```

---

### C-4: `read_file` and `list_dir` Tools — No Path Restrictions

**File:** `lib/kyber_beam/tool_executor.ex:45-70, 153-170`

Write operations are restricted to `@allowed_write_roots` but **reads are completely unrestricted**:

```elixir
# read_file and list_dir are NOT restricted (reads are safe).
def execute("read_file", %{"path" => path} = input) do
  expanded = Path.expand(path)
  case File.read(expanded) do
```

The LLM can be induced (via prompt injection from Discord) to call `read_file` on:
- `~/.openclaw/agents/main/agent/auth-profiles.json` — reads the OAuth token directly
- `~/.ssh/id_rsa` — reads private SSH keys
- `~/.aws/credentials`, `~/.gitconfig`, browser cookie stores
- The `deltas.jsonl` file containing full conversation history

**Impact:** Complete credential exfiltration via crafted Discord messages → prompt injection → `read_file`.

**Fix:**
- Add a read allowlist analogous to `@allowed_write_roots`, covering only `~/.kyber/`, `~/kyber-beam/`, and `/tmp/`.
- At minimum, add an explicit denylist blocking paths like `~/.openclaw/`, `~/.ssh/`, `~/.aws/`.
- The comment "reads are safe" is incorrect — reads expose credentials and private data.

---

## HIGH

---

### H-1: OAuth / Anthropic Token Exposed via LLM State Inspection

**File:** `lib/kyber_beam/introspection.ex:149-175`
**Tool:** `beam_genserver_state`

The `genserver_state` tool redacts `[:auth_config, :token, :api_key, :secret]` from the **top
level** of a GenServer's state map. However, `Kyber.Plugin.LLM`'s state stores auth as:

```elixir
%{
  auth_config: %{token: "sk-ant-oat01-...", type: :oauth},
  ...
}
```

The `redact_sensitive/1` function replaces the entire `auth_config` key with `"[REDACTED]"` — 
this works for the LLM plugin. However, the ElevenLabs `api_key` in `Kyber.Plugin.Voice` is
stored directly as `state.api_key` — this IS redacted. The Discord token is stored as `state.token`
— this IS also redacted. The redaction appears correct for current implementations but is fragile:
any new plugin that stores a token under a different key name (e.g. `:credentials`, `:bearer`,
`:access_token`) would NOT be redacted.

**Additional risk:** The `beam_genserver_state` tool is reachable via the tool loop, meaning a
crafted LLM response could call it to dump GenServer state during a compromised session.

**Fix:**
- Expand the sensitive key list to include `:credentials`, `:bearer`, `:access_token`, `:refresh_token`, `:session`.
- Consider a recursive redaction pass over nested maps.
- Log a warning when `genserver_state` is called on security-sensitive processes.

---

### H-2: `send_file` Has No Path Validation

**File:** `lib/kyber_beam/plugin/discord.ex:209-232`

```elixir
def send_file(token, channel_id, file_path, opts \\ []) do
  file_content = File.read!(file_path)   # ← no validation
  filename = Path.basename(file_path)
```

The `send_file` effect handler in the Discord plugin accepts a `file_path` directly from the
effect payload (which originates from an LLM tool call result). There is no validation that the
path is within safe bounds before reading and uploading the file to Discord.

**Impact:** The LLM can be induced to upload arbitrary files (SSH keys, credentials, etc.) to
a Discord channel. `File.read!/1` will raise if the file doesn't exist but will silently succeed
for any readable file.

**Fix:**
- Validate `file_path` against `@allowed_write_roots` (or a dedicated `@allowed_read_roots`) before reading.
- Replace `File.read!` with `File.read` and handle errors gracefully.

---

### H-3: WebSocket `/ws` and `GET /api/deltas` — No Authentication

**File:** `lib/kyber_beam/web/router.ex:57-64, 24-32`

The WebSocket endpoint streams **every delta** to any connected client with no authentication.
Deltas include full conversation content, system prompts, LLM responses, and metadata:

```elixir
get "/ws" do
  conn
  |> WebSockAdapter.upgrade(Kyber.Web.DeltaSocket, %{store: store_pid()}, timeout: 60_000)
  |> halt()
end
```

`GET /api/deltas` similarly returns all stored deltas (up to 10,000 in memory, or full history
from disk if `since` is omitted) to unauthenticated callers.

**Impact:** Any process on the network can eavesdrop on all conversations in real-time.

**Fix:**
- Add a shared secret or API key requirement to both endpoints.
- Bind the server to localhost-only in production config.

---

### H-4: Knowledge API — Vault Contents Exposed Without Authentication

**File:** `lib/kyber_beam/web/knowledge_controller.ex`
**Router:** `lib/kyber_beam/web/phoenix_router.ex:34-36`

The Phoenix router exposes the entire vault (personal notes, SOUL.md, MEMORY.md, daily notes,
relationship notes) via unauthenticated API:

```elixir
get "/knowledge/notes", Kyber.Web.KnowledgeController, :index
get "/knowledge/notes/*path", Kyber.Web.KnowledgeController, :show
```

The `show` action also uses `Enum.join(path_parts, "/")` without validating against `..` traversal
before passing to `Kyber.Knowledge.get_note/2`. While `normalize_path` in the Knowledge module
only strips leading `/`, a path like `../../etc/passwd.md` would be normalized but then fail with
`not_found` (the vault is constrained to `~/.kyber/vault`). This is safe by accident, not design.

**Impact:** All personal vault notes accessible to any unauthenticated network client.

**Fix:**
- Add authentication middleware to the `/api` scope of the Phoenix router.
- Add explicit `..` rejection in the controller before calling `get_note`.

---

### H-5: BEAM Distribution — Unauthenticated Delta Replication

**File:** `lib/kyber_beam/distribution.ex:122-134`

```elixir
def receive_remote_delta(%Kyber.Delta.t{} = delta) do
  GenServer.call(__MODULE__, {:receive_remote_delta, delta})
end
```

This public function is callable via `:erpc` from any Erlang node that connects to the BEAM
cluster. There is no authentication of which nodes are permitted to replicate. Any node that
can connect to the EPMD port can inject deltas into the local system, triggering the full
reducer pipeline including LLM calls.

**Impact:** If distribution is enabled, remote code injection via delta replication.

**Fix:**
- Use Erlang's distribution security (`.erlang.cookie` should be set to a strong random value, not the default).
- Add an explicit allowlist of permitted peer node names.
- Validate delta `kind` and `origin` before accepting remote deltas.

---

### H-6: `exec` Tool — Task Orphaning on Timeout

**File:** `lib/kyber_beam/tool_executor.ex:125-140`

The `exec` tool uses `Task.async + Task.yield` for timeout. When a timeout occurs, the `sh`
child process is orphaned (the comment acknowledges this):

```elixir
# NOTE: On timeout, the child sh process may become orphaned.
```

A crafted long-running command (e.g., `sleep 1000000 &`) will appear to time out but continue
running in the background, potentially:
- Exfiltrating data slowly over time
- Maintaining a persistent reverse shell
- Consuming system resources

**Fix:**
- Use `Port`-based execution with explicit OS PID tracking and `SIGKILL` on timeout.
- Alternatively, use a `:os.cmd` wrapper that sets process group and kills the group on timeout.

---

## MEDIUM

---

### M-1: `String.to_atom` on User-Supplied Input in Familiard

**File:** `lib/kyber_beam/familiard.ex:247`

```elixir
defp validate_level(level) when level in ["info", "warning", "critical"],
  do: {:ok, String.to_atom(level)}
```

While the guard `when level in [...]` prevents unbounded atom creation, using `String.to_atom`
instead of `String.to_existing_atom` is a code smell. These atoms likely already exist
(`:info`, `:warning`, `:critical`), so `String.to_existing_atom` is the safer idiom.

**Fix:** Replace with `String.to_existing_atom(level)`.

---

### M-2: No Rate Limiting on Discord Bot or LLM Calls

**File:** `lib/kyber_beam/plugin/discord.ex`, `lib/kyber_beam/plugin/llm.ex`

There is no per-user or per-channel rate limiting on:
- How many messages a Discord user can send to trigger LLM calls
- How many LLM API calls are made per time window
- How many tool-use iterations occur across concurrent sessions

A motivated user (or multiple users in a shared guild) could exhaust Anthropic API credits by
flooding the bot with mentions, each triggering an LLM call with up to 10 tool iterations.

**Fix:**
- Add per-channel/per-user rate limiting (e.g., max 5 LLM calls per minute per user).
- Implement a global token budget counter with circuit-breaker behavior.

---

### M-3: System Prompt Injection via `payload["system"]` Override

**File:** `lib/kyber_beam/plugin/llm.ex:357`

```elixir
system_prompt = payload["system"] || build_system_prompt(chat_id)
```

If the `llm_call` effect payload includes a `"system"` key, it overrides the entire system prompt
including SOUL.md, MEMORY.md, and the vault instruction. While `llm_call` effects are currently
only emitted by `Kyber.Reducer` (trusted code), the unauthenticated `POST /api/deltas` endpoint
allows injecting a `"message.received"` delta that flows through to `llm_call` with the original
payload — meaning `payload["system"]` from an untrusted source could reach the LLM.

Actually tracing the path: `POST /api/deltas` → `message.received` delta → reducer emits `llm_call`
effect with `payload: delta.payload` → `handle_llm_call` uses `payload["system"]`. This IS
exploitable if C-2 (unauthenticated API) is present.

**Fix:** Strip `"system"` from incoming delta payloads in the reducer before passing to `llm_call`.

---

### M-4: SSRF in `web_fetch` — Blocklist Bypassable via DNS Rebinding

**File:** `lib/kyber_beam/tool_executor.ex:269-308`

The SSRF guard uses a hostname blocklist:

```elixir
@blocked_hosts ["localhost", "127.0.0.1", "0.0.0.0", "169.254.169.254",
                "metadata.google.internal", "::1"]
```

This is bypassable via:
- DNS rebinding: resolve `attacker.com` to `127.0.0.1` after the check
- Non-standard loopback addresses: `127.0.0.2`, `0x7f000001`, `2130706433` (decimal IP)
- IPv6 mapped IPv4: `::ffff:127.0.0.1`
- Short hostnames that resolve to internal IPs

**Fix:**
- Perform the SSRF check on the **resolved IP** after DNS resolution, not just the hostname string.
- Use a library like `req` with a custom connect callback that validates the resolved address.
- Block entire `127.0.0.0/8` range, not just `127.0.0.1`.

---

### M-5: Hardcoded Dev `secret_key_base` in `config.exs`

**File:** `config/config.exs:8`

```elixir
secret_key_base: "kyber_beam_secret_key_base_at_least_64_chars_long_for_security_dev",
```

This is the base config (not env-specific). If `prod.exs` fails to override it (e.g., if
`SECRET_KEY_BASE` env var is missing), Phoenix falls back to this predictable value, allowing
session cookie forgery.

The `prod.exs` does properly `raise` if the env var is missing, which mitigates this — but the
base config should not contain a fallback value at all.

**Fix:** Remove the `secret_key_base` line from `config.exs` entirely. Let `prod.exs` raise and
`dev.exs` use an explicit dev-only value.

---

### M-6: Delta JSONL Contains Full Conversation History — File Permissions Unspecified

**File:** `lib/kyber_beam/delta/store.ex`, `config/config.exs`

The delta store persists all conversation content, LLM responses, system prompts, and metadata
to `priv/data/deltas.jsonl` (or `$KYBER_DATA_DIR/deltas.jsonl`). No file permission restrictions
are applied when the file is created.

On a multi-user system, this file may be world-readable, exposing all conversation history.
The file also contains the `"content"` field of `session.user` and `session.assistant` deltas,
including any sensitive information discussed with the bot.

**Fix:**
- Apply `File.chmod/2` with `0o600` after creation in `Delta.Store.init/1`.
- Document the sensitivity of this file and recommend protecting the `priv/data/` directory.

---

### M-7: Discord Interaction Tokens Persisted to Delta Log

**File:** `lib/kyber_beam/plugin/discord.ex:314-318`

Discord slash command interaction tokens (valid for 15 minutes, usable to send follow-up messages
as the bot) are stored in the delta payload:

```elixir
%{
  "interaction_token" => data["token"],
  "application_id" => application_id,
```

These tokens are then persisted to `deltas.jsonl` via `Delta.Store.append`. While 15-minute
expiry limits the window, the JSONL file persists indefinitely.

**Fix:**
- Strip `interaction_token` from the payload before persisting (keep it in-memory only).
- Alternatively, add an explicit ephemeral flag for interaction deltas to skip disk persistence.

---

## LOW

---

### L-1: Tool Input Logged at Debug Level May Include Sensitive Data

**File:** `lib/kyber_beam/plugin/llm.ex:470`

```elixir
Logger.debug("[Kyber.Plugin.LLM] executing tool: #{tool_name} #{inspect(tool_input)}")
```

If debug logging is enabled, `tool_input` is logged verbatim. For `write_file` or `exec` calls
with sensitive content (e.g., writing an OAuth token to a file), this would appear in logs.

**Fix:** Redact or summarize `tool_input` in the log: only log tool name and input keys, not values.

---

### L-2: Bot User ID Hardcoded in Discord Plugin

**File:** `lib/kyber_beam/plugin/discord.ex`

```elixir
@bot_user_id "1483371308606816316"
@liet_user_id "1466660860582821995"
```

These are hardcoded module attributes. If the bot is migrated to a new application or the Liet
bot's ID changes, the hardcoded values silently break message filtering (the bot may start
responding to its own messages or ignoring Liet's).

**Fix:** Load these from config or from the READY event (`application.id` and `user.id` fields).
The READY handler already captures `application_id` — extend it to capture the bot's own user ID.

---

### L-3: No Input Length Validation on Discord Messages

**File:** `lib/kyber_beam/plugin/discord.ex:build_message_delta/1`

Discord messages can be up to 2000 characters, but there is no maximum length check on the
`content` field before it's passed to the LLM. While the API handles this, a very long message
could:
- Fill LLM context with junk, crowding out the actual conversation history.
- Cause unexpected behavior if combined with image attachments (large content blocks).

**Fix:** Truncate user message content at a reasonable limit (e.g., 4000 characters) before
building the LLM payload.

---

### L-4: `cron_jobs.jsonl` Contains Reminder Text in Plaintext

**File:** `lib/kyber_beam/cron.ex:314-319`

Reminder labels (the `message` param to `add_reminder/3`) are stored in `~/.kyber/cron_jobs.jsonl`
as plaintext in the `metadata.label` field. If this file is shared or backed up insecurely,
reminder content is exposed.

This is low severity for a personal tool but worth noting.

---

### L-5: Cron Expression Parsing — No Bounds on Iteration

**File:** `lib/kyber_beam/cron.ex:compute_next_cron/2`

The `find_match/3` function iterates minute-by-minute up to 525,601 times (366 days) to find
the next cron trigger. An adversarially crafted cron expression that matches no valid time (e.g.,
`0 0 31 2 *` — Feb 31st) would cause this loop to run to its limit before returning. If cron jobs
are added via the LLM (which has `add_job` accessible) or the REST API, this is a DoS vector.

**Fix:** Cap the search at 366 days (already done, ✓) and return an error rather than silently
returning an arbitrary future time when no match is found.

---

### L-6: `beam_genserver_state` Accessible Without Access Control

**File:** `lib/kyber_beam/introspection.ex:152-157`
**Tool:** `beam_genserver_state`

Any LLM session can call `beam_genserver_state` on arbitrary named processes including those not
owned by kyber-beam (e.g., `Logger`, `:global`, ETS owner processes). While `String.to_existing_atom`
limits names to already-loaded atoms (good), the tool can still expose internal GenServer state
of third-party libraries.

**Fix:** Add an allowlist of permitted process names for `beam_genserver_state` (e.g., only
`Kyber.*` modules), similar to how `beam_reload_module` enforces the `"Elixir.Kyber."` prefix.

---

## Test Gap Analysis

The following security-relevant behaviors lack test coverage:

1. **FamiliardController** — No test verifying that unsigned requests are rejected (because the
   check doesn't exist). No tests for the signature verification path at the controller level.

2. **REST API Authentication** — No tests asserting that unauthenticated requests to `/api/deltas`
   or `/ws` are rejected (they aren't rejected, which is the bug).

3. **`read_file` path traversal** — `test/kyber_beam/plugin/discord_test.exs:521` tests
   snowflake validation, but there are no tests for `read_file` reading sensitive paths like
   `~/.ssh/` or `~/.openclaw/`.

4. **`exec` injection** — No tests for the `exec` tool with injection-style payloads (semicolons,
   subshells, etc.).

5. **SSRF bypass** — No tests for `web_fetch` with non-standard loopback addresses like `0x7f000001`
   or `::ffff:127.0.0.1`.

6. **`beam_genserver_state` redaction completeness** — No test for nested sensitive fields
   (e.g., a map-within-map containing a `:token` key).

---

## Prioritized Fix Order

1. **C-3** — Add signature verification to FamiliardController (5 min fix, high impact)
2. **C-2** — Add API token authentication to REST endpoints, or bind to localhost (low effort)
3. **C-4** — Add path restrictions to `read_file` and `list_dir` (30 min, critical for credential safety)
4. **H-2** — Add path validation to `send_file` (10 min)
5. **H-3/H-4** — Add authentication to WebSocket and Knowledge API (1-2 hours)
6. **C-1** — Add approval gate or denylist to `exec` tool (design decision needed)
7. **M-3** — Strip `"system"` from incoming delta payloads in reducer
8. **H-6** — Replace Task-based exec with Port+SIGKILL for proper timeout handling
9. **M-7** — Mark interaction deltas as ephemeral (skip JSONL persistence)
10. **M-6** — Set `chmod 0o600` on the deltas.jsonl file at store startup

---

*End of audit. This is a read-only review — no changes were made to the codebase.*
