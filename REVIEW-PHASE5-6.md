# Staff Engineer Review: Phases 5 & 6

**Reviewer:** Liet (subagent)  
**Date:** 2026-03-19  
**Files reviewed:** `plugin/llm.ex`, `tools.ex`, `tool_executor.ex`, `introspection.ex`  
**Test files reviewed:** `tool_executor_test.exs`, `introspection_test.exs`, `llm_test.exs`, `knowledge_test.exs`

---

## HIGH Severity

### H1: `memory_write` path traversal is bypassable via symlinks

**File:** `tool_executor.ex:131-143`

The current protection normalizes `..` but does NOT resolve symlinks. An attacker (the LLM) could craft a path like `memory/innocent.md` where `memory/` is a pre-existing symlink to `/etc/` or another sensitive directory. `Path.expand/1` resolves `..` but not symlinks in intermediate components.

```elixir
# Current code
normalized = String.trim_leading(path, "/")
abs_path = Path.expand(Path.join(@vault_path, normalized))
unless String.starts_with?(abs_path, @vault_path) do
```

**Fix:** Add `File.read_link/1` or use `:file.read_link_info/1` on parent directories, or better — resolve the real path after expansion:

```elixir
def execute("memory_write", %{"path" => path, "content" => content}) do
  normalized = String.trim_leading(path, "/")
  # Reject any path component that is ".."
  if String.contains?(normalized, "..") do
    {:error, "path must not contain '..' components"}
  else
    abs_path = Path.join(@vault_path, normalized)
    # Ensure the parent directory exists and resolve to real path
    parent = Path.dirname(abs_path)
    File.mkdir_p(parent)
    # After mkdir_p, resolve real path to catch symlink escapes
    case :file.read_link_info(to_charlist(parent)) do
      {:ok, info} ->
        real_parent = case File.read_link(parent) do
          {:ok, target} -> Path.expand(target)
          {:error, _} -> parent  # not a symlink
        end
        real_abs = Path.join(real_parent, Path.basename(abs_path))
        unless String.starts_with?(real_abs, @vault_path) do
          {:error, "resolved path escapes vault: #{path}"}
        else
          # ... write ...
        end
      _ -> {:error, "cannot resolve parent directory"}
    end
  end
end
```

**Simpler pragmatic fix:** Just reject any path containing `..` or starting with `/` and ban symlinks in vault entirely:

```elixir
if String.contains?(normalized, "..") or String.starts_with?(normalized, "/") do
  {:error, "invalid vault path: must be relative with no '..' components"}
else
  # proceed
end
```

**Risk:** If the vault directory itself contains symlinks (unlikely for a personal project, but worth hardening).

---

### H2: `beam_reload_module` has no allowlist — arbitrary module reload

**File:** `tool_executor.ex:247-267`, `introspection.ex:241-262`

Any module the LLM names can be hot-reloaded, including `:kernel`, `:stdlib`, or even `Kyber.ToolExecutor` itself. Reloading system modules can crash the VM. Reloading `Kyber.ToolExecutor` mid-execution is undefined behavior.

**Fix:** Add an allowlist of reloadable module prefixes:

```elixir
@reloadable_prefixes ["Kyber.", "KyberBeam."]

def reload_module(module_name) when is_atom(module_name) do
  mod_str = to_string(module_name)
  unless Enum.any?(@reloadable_prefixes, &String.starts_with?(mod_str, "Elixir." <> &1)) do
    {:error, "module #{module_name} is not in the reload allowlist"}
  else
    # ... existing reload logic ...
  end
end
```

---

### H3: `beam_genserver_state` leaks auth tokens

**File:** `introspection.ex:119-131`, `tool_executor.ex:222-231`

Calling `beam_genserver_state` with `name: "Kyber.Plugin.LLM"` will return the full GenServer state including `auth_config` with the Anthropic API token / OAuth token. The LLM sees its own auth token in tool results and could potentially leak it in responses to users.

The `inspect(state, limit: 50)` truncation helps but doesn't guarantee the token is excluded — short states will show it fully.

**Fix:** Either:
1. Redact known sensitive fields before returning:
```elixir
def genserver_state(name) when is_atom(name) do
  try do
    state = :sys.get_state(name, 5_000)
    sanitized = redact_sensitive(state)
    full = inspect(sanitized, limit: 50, pretty: true)
    {:ok, String.slice(full, 0, 10_240)}
  catch
    # ...
  end
end

defp redact_sensitive(%{auth_config: _} = state),
  do: %{state | auth_config: "[REDACTED]"}
defp redact_sensitive(state), do: state
```

2. Or maintain a denylist of process names that can't be state-inspected.

---

## MEDIUM Severity

### M1: `web_fetch` has no SSRF protection

**File:** `tool_executor.ex:155-178`

The only validation is `String.starts_with?(url, ["http://", "https://"])`. The LLM can request:
- `http://169.254.169.254/latest/meta-data/` (cloud metadata)
- `http://localhost:4000/admin/` (internal services)
- `http://[::1]:4369/` (EPMD, Erlang port mapper)

For a personal laptop this is lower risk than cloud, but EPMD on port 4369 is particularly concerning — it could expose node names and enable distribution attacks.

**Fix:** Add a hostname blocklist:

```elixir
@blocked_hosts ["localhost", "127.0.0.1", "::1", "169.254.169.254",
                "metadata.google.internal", "0.0.0.0"]

defp ssrf_safe?(url) do
  uri = URI.parse(url)
  host = uri.host || ""
  not (host in @blocked_hosts or
       String.starts_with?(host, "10.") or
       String.starts_with?(host, "192.168.") or
       String.starts_with?(host, "172.") or  # simplified; proper check: 172.16-31
       String.ends_with?(host, ".internal"))
end
```

---

### M2: `web_fetch` timeout is request-level only — no connection timeout

**File:** `tool_executor.ex:163`

`receive_timeout: 10_000` only covers the response body read. There's no `connect_timeout`, so DNS resolution + TCP handshake to a slow/black-hole host can hang much longer.

**Fix:**
```elixir
Req.get(url,
  connect_options: [timeout: 5_000],
  receive_timeout: 10_000,
  decode_body: false
)
```

---

### M3: `String.to_existing_atom` in BEAM tools — atom table probing

**File:** `tool_executor.ex:219, 224, 236, 243, 250, 260`

Six BEAM tool handlers use `String.to_existing_atom(name)` which is safe from atom table exhaustion. However, the `rescue ArgumentError` pattern means the LLM gets a clean error for typos. This is fine.

**BUT** — `beam_reload_module` at line 250 uses `String.to_existing_atom("Elixir." <> mod)` with a fallback to `String.to_existing_atom(mod)`. This is correct behavior.

No action needed on this one — just confirming the pattern is safe. ✅

---

### M4: `memory_list` subdir has no path traversal protection

**File:** `tool_executor.ex:147-160`

```elixir
search_root =
  if subdir && subdir != "" do
    Path.join(@vault_path, String.trim_leading(subdir, "/"))
  else
    @vault_path
  end
```

Passing `subdir: "../../"` would let the LLM list files outside the vault. While `File.dir?` check prevents crashes, the wildcard `Path.wildcard(Path.join([search_root, "**", "*.md"]))` would traverse arbitrary directories.

**Fix:** Same as H1 — reject `..` in subdir:
```elixir
if subdir && String.contains?(subdir, "..") do
  {:error, "subdir must not contain '..' components"}
else
  # proceed
end
```

---

### M5: Knowledge context injection could produce duplicate system prompt blocks

**File:** `llm.ex:200-216` (`build_system_prompt`) and `llm.ex:125-145` (`call_api`)

`build_system_prompt` returns a string combining SOUL.md + memory context. Then `call_api` wraps it:
- OAuth: `[{text: "Claude Code..."}, {text: system_prompt}]`
- API key: plain string

This works correctly. The OAuth path always prepends the Claude Code identity block. The knowledge context is appended after SOUL.md in `build_system_prompt`.

**Potential issue:** If `build_system_prompt` returns `nil` (SOUL.md not found, no memory), the system prompt becomes `nil <> ""` which raises. Actually — `(soul_content || "") <> memory_context` handles nil correctly. ✅

However, `build_system_prompt` ignores the `chat_id` parameter entirely (unused). This is a dead parameter — clean it up.

**Fix:** Remove the unused `_chat_id` parameter or document why it's there for future use.

---

### M6: `exec` timeout doesn't kill orphaned `sh` processes

**File:** `tool_executor.ex:97-111`

The comment at line 101 acknowledges this: `Task.shutdown(task)` sends an exit signal to the Elixir Task, but the child `sh -c` process can survive. On macOS, this means timed-out `sleep` or `curl` commands become orphans.

**Fix (documented, not blocking):** Switch to `Port.open` with OS PID tracking, or use `System.cmd` with a wrapper script that traps signals. For a personal agent, this is acceptable tech debt but should be tracked.

---

### M7: `ets_inspect` calls `tab2list` — can OOM on large tables

**File:** `introspection.ex:168-186`

```elixir
:ets.tab2list(table_name)
|> Enum.take(5)
```

This reads the ENTIRE table into memory before taking 5 elements. For a table with millions of rows this could OOM the VM.

**Fix:** Use `:ets.first/1` + `:ets.next/2` to sample:
```elixir
sample_keys =
  case :ets.first(table_name) do
    :"$end_of_table" -> []
    first_key ->
      Stream.unfold(first_key, fn
        :"$end_of_table" -> nil
        key -> {key, :ets.next(table_name, key)}
      end)
      |> Enum.take(5)
      |> Enum.map(&inspect/1)
  end
```

---

## LOW Severity

### L1: `format_map` for nested maps produces unreadable output

**File:** `tool_executor.ex:301-307`

`format_map` only handles one level — nested maps (like `by_kind` in delta stats, or `counts` in supervision tree) get `inspect`'d as Elixir literals, which are harder for the LLM to parse.

**Fix:** Recursive formatting or use `Jason.encode!` with `:pretty`:
```elixir
defp format_map(map) when is_map(map) do
  case Jason.encode(map, pretty: true) do
    {:ok, json} -> json
    _ -> inspect(map, pretty: true)
  end
end
```

---

### L2: `top_processes` registered_name pattern match

**File:** `introspection.ex:60`

```elixir
case info[:registered_name] do
  [] -> inspect(pid)
  name -> to_string(name)
end
```

`Process.info(pid, :registered_name)` returns `[]` when no name is registered — this is correct Erlang behavior. However, if the process dies between `Enum.map` and `Process.info`, `info` is `nil` and the code handles it with the `if info do` guard. ✅

---

### L3: `build_system_prompt` file fallback paths

**File:** `llm.ex:235-243`

`load_soul_from_file` tries `~/.kyber/vault/identity/SOUL.md` then `:code.priv_dir(:kyber_beam)`. This is a reasonable fallback chain.

Note: `safe_knowledge_call` uses `Process.whereis(Kyber.Knowledge)` which is fine for the globally-registered name, but won't work if Knowledge is started with `name: nil` (as in tests). This is acceptable since `build_system_prompt` is only called from the LLM plugin which runs in the full application context.

---

### L4: No rate limiting on `web_fetch`

The LLM can call `web_fetch` in rapid succession with no throttling. For a personal agent this is acceptable, but if exposed to multiple users, could be used for DDoS amplification.

**Fix (future):** Add a simple token bucket or per-minute counter.

---

### L5: `beam_gc` on `:all` is a stop-the-world operation

**File:** `introspection.ex:215-224`

`Enum.each(&:erlang.garbage_collect/1)` iterates all processes and GCs them synchronously. On a system with thousands of processes this could cause noticeable latency spikes.

**Fix:** Consider async GC or limiting to top-N memory consumers. Low priority for a personal agent.

---

## Integration Assessment

### Tool coexistence in `tools.ex` ✅

- 5 Phase 4 tools + 4 Phase 5 tools + 14 Phase 6 tools = 23 total
- No naming collisions — Phase 5 uses `memory_*` / `web_*` prefix, Phase 6 uses `beam_*` prefix
- All tools properly listed in `@tools` module attribute
- `Kyber.Tools.definitions/0` returns flat list — no ordering issues

### Tool coexistence in `tool_executor.ex` ✅

- Each tool has its own `execute/2` clause with pattern matching on name string
- Catch-all `execute(name, _input)` at the bottom handles unknown tools
- No shared mutable state between handlers (pure functions, as documented)
- The `@vault_path` and `@allowed_write_roots` compile-time constants don't conflict

### Knowledge context injection in LLM ✅

- `build_system_prompt` loads SOUL.md + daily memory, both optional
- Falls back gracefully when `Kyber.Knowledge` is not running
- Does NOT break the OAuth system prompt — `call_api` correctly wraps the result
- The Claude Code identity prefix is always first in the OAuth path

---

## Test Coverage Gaps

### Critical gaps (should add):

1. **`memory_write` path traversal with `..` in middle** — test exists for `../../../etc/passwd` but not for `memory/../../../etc/passwd` or symlink-based escapes
2. **`memory_list` path traversal** — no test for `subdir: "../../"` 
3. **`beam_genserver_state` on LLM plugin** — no test verifying token redaction
4. **`beam_reload_module` on system modules** — no test verifying rejection of `:kernel` or `:stdlib`
5. **`web_fetch` with localhost/internal URLs** — no SSRF test
6. **`build_system_prompt` integration** — no test that verifies the system prompt includes SOUL.md content when Knowledge is running
7. **`ets_inspect` on a large table** — no test verifying memory safety

### Nice-to-have:

8. **`beam_inspect_process` on a dead PID** — test exists for nonexistent name but not for a PID that died mid-inspection
9. **`beam_supervision_tree` depth recursion** — no test for depth > 2
10. **`web_fetch` with redirect chains** — Req follows redirects by default, but no test verifying behavior
11. **`introspection.ex` `reload_module`** — test file exists but no reload test (likely because it's destructive)
12. **Tool loop max iterations** — `llm_test.exs` doesn't test the tool loop at all (only unit tests for auth/messages)

---

## Summary

| Severity | Count | Key themes |
|----------|-------|------------|
| HIGH     | 3     | Path traversal symlink bypass, unrestricted module reload, auth token leakage via state inspection |
| MEDIUM   | 7     | SSRF, timeout gaps, OOM risk in ETS inspection, orphaned processes |
| LOW      | 5     | Formatting, rate limiting, GC impact, dead parameters |

**Overall assessment:** Solid implementation with clean separation of concerns. The BEAM introspection tools are unique and well-structured. The main risks are security hardening items that are typical for a "personal agent on a laptop" context but would be critical if this ever runs multi-tenant. The `memory_write` path traversal and `beam_genserver_state` token leakage are the most important items to fix before any broader deployment.

The test coverage is good for happy paths but needs adversarial/security test cases for the vault and web tools.
