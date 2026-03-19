# Phase 4 Code Review — Conversation History + Tool Use

**Reviewer:** Liet (staff eng review)  
**Date:** 2026-03-19  
**Files reviewed:** `tools.ex`, `tool_executor.ex`, `plugin/llm.ex`, `tools_test.exs`, `tool_executor_test.exs`

---

## Summary

| Severity | Count | Areas |
|----------|-------|-------|
| **HIGH** | 3 | Shell injection, path traversal, race condition on session state |
| **MEDIUM** | 5 | Timeout kill semantics, unbounded output, history bloat, missing error paths, exec workdir validation |
| **LOW** | 4 | Code style, minor edge cases, test gaps |

Overall: solid structure, clean Elixir, good separation of concerns. The tool loop logic is correct in the happy path. The issues are mostly around security hardening and edge cases that matter when an LLM is driving tool execution.

---

## HIGH Severity

### H1. No shell injection mitigation in `exec` tool

**File:** `tool_executor.ex:82-83`

The LLM provides the `command` string, which goes directly to `sh -c`. The model can run anything: `rm -rf /`, write to `/etc`, exfiltrate data, etc. There's zero sandboxing.

**This is by design for a personal machine bot**, but you should at minimum:
1. Log every command before execution
2. Consider a denylist for obviously destructive patterns
3. Consider restricting to a specific user or directory

**Suggested minimum fix — add logging (already partially done in llm.ex, but add it in executor too):**

```elixir
def execute("exec", %{"command" => cmd} = input) do
  Logger.warning("[Kyber.ToolExecutor] exec: #{String.slice(cmd, 0, 500)}")
  # ... rest of function
end
```

**Optional denylist (pragmatic, not bulletproof):**

```elixir
@dangerous_patterns ~w(rm\ -rf sudo mkfs dd\ if= :(){ passwd)

defp dangerous_command?(cmd) do
  Enum.any?(@dangerous_patterns, &String.contains?(cmd, &1))
end
```

### H2. No path restrictions on `write_file` / `edit_file`

**File:** `tool_executor.ex:38-39, 53-54`

The LLM can write to any file the BEAM process has permission to access: `~/.ssh/authorized_keys`, `~/.zshrc`, crontabs, etc. `Path.expand/1` faithfully expands `~` so `~/../../etc/passwd` still resolves.

**Fix — allowlist approach:**

```elixir
@allowed_roots [
  Path.expand("~/kyber-beam"),
  Path.expand("~/projects"),
  System.tmp_dir!()
]

defp path_allowed?(expanded) do
  Enum.any?(@allowed_roots, &String.starts_with?(expanded, &1))
end
```

Then guard in `write_file` and `edit_file`:

```elixir
def execute("write_file", %{"path" => path, "content" => content}) do
  expanded = Path.expand(path)
  unless path_allowed?(expanded), do: throw({:error, "write blocked: #{expanded} outside allowed roots"})
  # ...
end
```

### H3. Race condition — tool loop runs in caller's process, but session writes are unprotected

**File:** `llm.ex:156-175` (handle_llm_call) and `llm.ex:214-269` (run_tool_loop)

The effect handler closure runs in whatever process calls it (likely the Core executor process or a Task). If two messages arrive for the same `chat_id` concurrently:

1. Both read history at the same time
2. Both store user messages
3. Both run tool loops
4. Both store assistant responses
5. History gets interleaved/corrupted

The `Kyber.Session` ETS access pattern matters here. If `add_message` is a simple `ets:insert`, concurrent writers can produce inconsistent ordering.

**Fix options:**
1. **Simplest:** Serialize per-chat by routing through a per-channel GenServer or using `:global` locks
2. **Good enough:** Add a mutex/lock in Session per chat_id:

```elixir
# In Kyber.Session
def with_lock(session, chat_id, fun) do
  # Use :global.trans or a simple GenServer-based lock
  :global.trans({__MODULE__, chat_id}, fn -> fun.() end, [node()], :infinity)
end
```

3. **Acceptable for now:** Document that concurrent messages to the same channel will race, and consider it a known limitation. For a single-user Discord bot, this is unlikely to be a real problem.

---

## MEDIUM Severity

### M1. `System.cmd` output is unbounded

**File:** `tool_executor.ex:87-90`

If the command produces gigabytes of output (e.g., `cat /dev/urandom | head -c 100000000`), the entire output is held in memory and then sent to the LLM API (which will reject it).

**Fix — truncate output:**

```elixir
{:ok, {output, 0}} ->
  truncated = String.slice(output, 0, 100_000)
  suffix = if byte_size(output) > 100_000, do: "\n[truncated: #{byte_size(output)} bytes total]", else: ""
  {:ok, truncated <> suffix}
```

### M2. `Task.shutdown/1` doesn't kill the child `sh` process

**File:** `tool_executor.ex:93-96`

When `Task.yield` returns `nil` and `Task.shutdown` kills the Task, the spawned `sh -c <cmd>` process is **not** killed — it becomes an orphan. `System.cmd` doesn't give you the OS PID to kill.

**Fix — use `Port` directly for killable processes, or use `os:cmd` with process group tracking. Pragmatic alternative:**

```elixir
# Wrap command with timeout to let the OS handle it
def execute("exec", %{"command" => cmd} = input) do
  timeout_s = div(Map.get(input, "timeout_ms", 30_000), 1000)
  wrapped = "timeout #{timeout_s} sh -c #{:os.cmd('printf "%q" \'#{cmd}\'')}"
  # ... or simpler:
  wrapped = "timeout #{timeout_s} sh -c '#{String.replace(cmd, "'", "'\\''")}'
```

Actually that gets hairy. Simplest pragmatic fix: just document it and accept orphans can happen on timeout. For a personal machine, it's fine. But add a note:

```elixir
# NOTE: On timeout, the child sh process may become orphaned.
# For production use, switch to Port-based execution with OS PID tracking.
```

### M3. History grows without bound

**File:** `llm.ex:156-175`

Every message is appended to session history forever. After a long conversation, the messages list will exceed the API's context window, and the API call will fail with a 400.

**Fix — sliding window or token counting:**

```elixir
# Simple: keep last N messages
messages = Enum.take(history, -50) ++ [%{"role" => "user", "content" => text}]
```

Better: count tokens and truncate from the front. But for Phase 4, a simple cap is fine.

### M4. Tool results with `is_error: true` — Anthropic wants a string, not boolean

**File:** `llm.ex:249-254`

The Anthropic API expects `"is_error"` to be `true` (boolean). This looks correct, but double-check the API spec — some versions want `is_error` as a boolean, others don't document it. If the API ignores it, the model won't know the tool failed and may hallucinate success.

**Verify:** Test with a failing tool call and confirm the model's response acknowledges the error.

### M5. `exec` workdir not validated

**File:** `tool_executor.ex:83`

If the LLM provides a nonexistent `workdir`, `System.cmd` will raise (not return an error tuple). The `rescue` block catches it, but you get a cryptic error.

**Fix — validate before calling:**

```elixir
expanded_dir = Path.expand(workdir)
unless File.dir?(expanded_dir) do
  {:error, "workdir does not exist: #{expanded_dir}"}
end
```

(Would need to restructure the function to early-return, or use a `with` block.)

---

## LOW Severity

### L1. `extract_content` only handles text blocks after tool loop

**File:** `llm.ex:282-290`

After the tool loop completes, `extract_content` pulls text from the final response. But the final response might contain both `text` and `tool_use` blocks (if the model did a tool call AND provided text in the same turn, then `stop_reason` was `end_turn`). This is handled correctly — `extract_content` filters for text blocks. But if the final response has NO text blocks (only tool_use), it returns `""` which gets stored as an empty assistant message.

**Minor fix:** Skip storing empty assistant messages:

```elixir
if chat_id && process_alive?(session) && content != "" do
  # store assistant delta
end
```

### L2. `edit_file` with `global: false` — good but document it

**File:** `tool_executor.ex:60`

Using `global: false` (replace first occurrence only) is the right call for a code editing tool. The test covers this. Just add a comment explaining why:

```elixir
# Only replace first occurrence — matching Claude Code's behavior
new_content = String.replace(content, old, new, global: false)
```

### L3. Missing type spec on `run_tool_loop`

**File:** `llm.ex:214`

`run_tool_loop/4` is a private function but it's complex enough to benefit from a spec or at least a more detailed `@doc`:

```elixir
@spec run_tool_loop([map()], String.t() | nil, map(), non_neg_integer()) ::
        {:ok, map()} | {:error, map() | String.t()}
```

### L4. Test cleanup could use `ExUnit.TmpDir`

**File:** `tool_executor_test.exs` throughout

The manual `tmp_path` + `on_exit` cleanup pattern works but is verbose. If on ExUnit 1.15+, `@tag :tmp_dir` is cleaner. Minor style point.

---

## Missing Test Cases

### Critical gaps:

1. **No integration test for the tool loop** — `run_tool_loop` is private and never tested. You'd need to either:
   - Make it public (or `@doc false` + `@spec`)
   - Test through the full `handle_llm_call` path with a mock API
   - At minimum, test the message construction (assistant + tool_result format)

2. **No test for concurrent session access** — hard to test, but worth a simple test showing two concurrent tool executions don't corrupt shared state.

3. **No test for `exec` with special characters in command** — e.g., `echo "hello 'world'"`, commands with pipes, semicolons, backticks.

4. **No test for `read_file` with binary/non-UTF8 content** — `String.split` on binary data could produce unexpected results.

5. **No test for `write_file` to a read-only location** — verify the error path works.

6. **No test for the tool loop hitting max iterations** — would need API mocking.

7. **No test for `edit_file` with empty `old_string`** — `String.contains?("anything", "")` returns `true`, so empty old_string would match and prepend `new_string`. This is probably a bug:

```elixir
# This will match and produce unexpected results:
ToolExecutor.execute("edit_file", %{
  "path" => path,
  "old_string" => "",
  "new_string" => "injected"
})
```

**Fix:**
```elixir
def execute("edit_file", %{"path" => _path, "old_string" => ""}) do
  {:error, "old_string cannot be empty"}
end
```

### Nice-to-have test cases:

8. **`read_file` with offset > total lines** — should return empty or a sensible message
9. **`list_dir` on a directory with symlinks** — does it follow them?
10. **`exec` with very long output** — verify behavior (currently unbounded, see M1)

---

## Architecture Notes (not bugs, just observations)

1. **Tool execution is synchronous and serial** — tool calls in a single turn are executed one at a time via `Enum.map`. For a personal bot this is fine, but if you later add slow tools (HTTP requests, etc.), consider `Task.async_stream` with a timeout.

2. **The effect handler closure captures `core` and `session` atoms** — if either process restarts, the handler keeps working because it references the registered name. Good design.

3. **`load_soul/0` is called on every LLM invocation** — it reads from disk each time. Consider caching in GenServer state with a periodic refresh, or just accept the disk read (it's fast for small files).

4. **The tool definitions in `tools.ex` are compile-time constants (`@tools`)** — this is efficient but means you can't add tools at runtime. Fine for now.

---

## Verdict

**Ship it with these fixes applied first:**
1. **H2** (path restrictions on write/edit) — most important, takes 10 minutes
2. **M1** (truncate exec output) — prevents OOM, takes 5 minutes  
3. **M3** (cap history length) — prevents API failures, takes 5 minutes
4. The empty `old_string` bug (test gap #7) — 2-minute fix

Everything else is either acceptable risk for a personal machine or can be addressed in a follow-up phase.

The code is clean, well-structured, and the test coverage for the executor is solid. The main gaps are in integration testing of the tool loop and security hardening for LLM-driven file/shell access.
