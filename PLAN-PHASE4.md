# Kyber-Beam: Phase 4+ Engineering Plan

**Baseline:** Phase 3 complete (commit `1d4fa22`)  
**Goal:** Feature parity with OpenClaw, plus capabilities OpenClaw can never have  
**Author:** Stilgar (Liet subagent), 2026-03-18

---

## State Audit: What's Broken vs. What's Missing

Before planning forward, it's worth being precise about two categories:

**Buggy / wired incorrectly (needs fixing, not building):**
- `Kyber.Session` exists but the LLM plugin reads it wrong — maps every stored delta to a user message, never stores assistant responses, never writes back after generation. Conversation history is effectively non-functional.
- Cron heartbeat fires `"cron.fired"` → reducer emits `:llm_call` with `text: "[heartbeat] check in"` and `origin: {:cron, "heartbeat"}` — but there's no channel_id, so the response generates a `"llm.response"` delta with no `:send_message` effect. The heartbeat speaks to no one.
- `Kyber.Familiard` is fully implemented but not started in `application.ex`. It's dead code.

**Genuinely missing (needs building):**
- Tool use (definitions, multi-turn loop, executor)
- Knowledge context injection into LLM calls
- Proactive Discord message sending (distinct from responding)
- Streaming responses
- Error recovery / retry
- Rich Discord interactions (reactions, threads)
- Context window management
- BEAM introspection tools (unique to kyber-beam — detailed below)

---

## Phase 4: Conversation History + Basic Tools

**Target:** Stilgar can hold a multi-turn conversation and use tools to read files, write files, and run shell commands. This is the minimum for genuine usefulness.

**Estimated LOC:** ~900  
**Complexity:** High (tool loop is the core architectural change)  
**Shippable as:** Stilgar can now help with real tasks in Discord — read a file, run a command, explain what he found.

---

### 4.1 Fix Conversation History

**Problem:** `Kyber.Plugin.LLM` (`lib/kyber_beam/plugin/llm.ex`) reads session history in `handle_llm_call/4` but:
1. Maps every delta to `%{"role" => "user", ...}` — ignores that assistant turns exist
2. Never writes back to session after generating a response
3. Never writes the user's incoming message to session before calling the API

**Fix — Session writes in the right places:**

`lib/kyber_beam/plugin/llm.ex` — in `handle_llm_call/4`:

```elixir
# 1. Before API call: write user message to session
if chat_id && Process.whereis(session) do
  user_delta = Kyber.Delta.new("session.user", %{"role" => "user", "content" => text}, origin)
  Kyber.Session.add_message(session, chat_id, user_delta)
end

# 2. After successful response: write assistant turn
if chat_id && Process.whereis(session) do
  asst_delta = Kyber.Delta.new("session.assistant", %{"role" => "assistant", "content" => content}, origin)
  Kyber.Session.add_message(session, chat_id, asst_delta)
end
```

**Fix — Session reads produce proper alternating messages:**

```elixir
# In handle_llm_call, replace the broken history builder:
history =
  if chat_id && Process.whereis(session) do
    Kyber.Session.get_history(session, chat_id)
    |> Enum.map(fn delta ->
      role = Map.get(delta.payload, "role", "user")
      content = Map.get(delta.payload, "content", "")
      %{"role" => role, "content" => content}
    end)
  else
    []
  end
```

**Files changed:** `lib/kyber_beam/plugin/llm.ex`  
**LOC:** ~40

---

### 4.2 Tool Definitions Module

New file: `lib/kyber_beam/tools.ex`

This module owns the canonical tool schema list. Tools are defined once here and referenced by the LLM plugin when building API calls.

```elixir
defmodule Kyber.Tools do
  @moduledoc """
  Tool definitions for Stilgar's tool use capability.
  
  Each tool is an Anthropic-format tool definition map. The executor
  registry maps tool names to handler functions.
  """

  @tools [
    %{
      "name" => "read_file",
      "description" => "Read the contents of a file at the given path.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute or ~-relative file path"},
          "offset" => %{"type" => "integer", "description" => "Line number to start reading from (1-indexed)"},
          "limit" => %{"type" => "integer", "description" => "Max lines to return"}
        },
        "required" => ["path"]
      }
    },
    %{
      "name" => "write_file",
      "description" => "Write content to a file, creating it if it doesn't exist.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "content" => %{"type" => "string"}
        },
        "required" => ["path", "content"]
      }
    },
    %{
      "name" => "edit_file",
      "description" => "Replace an exact string in a file with new text.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"},
          "old_string" => %{"type" => "string"},
          "new_string" => %{"type" => "string"}
        },
        "required" => ["path", "old_string", "new_string"]
      }
    },
    %{
      "name" => "exec",
      "description" => "Run a shell command. Returns stdout, stderr, and exit code.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{"type" => "string", "description" => "Shell command to run"},
          "workdir" => %{"type" => "string", "description" => "Working directory"},
          "timeout_ms" => %{"type" => "integer", "description" => "Timeout in milliseconds (default 30000)"}
        },
        "required" => ["command"]
      }
    },
    %{
      "name" => "list_dir",
      "description" => "List files and directories at a path.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string"}
        },
        "required" => ["path"]
      }
    }
  ]

  def definitions, do: @tools
  def names, do: Enum.map(@tools, & &1["name"])
end
```

**Files created:** `lib/kyber_beam/tools.ex`  
**LOC:** ~80

---

### 4.3 Tool Executor

New file: `lib/kyber_beam/tool_executor.ex`

Pure functions (no GenServer needed) that execute each tool by name with its input map. Returns `{:ok, result_string}` or `{:error, reason_string}`. Results are always strings — they go directly into `tool_result` content blocks.

```elixir
defmodule Kyber.ToolExecutor do
  @moduledoc """
  Executes tool calls by name. Pure functions — no process, no state.
  
  All handlers return {:ok, string} or {:error, string}.
  The string goes directly into the tool_result content block.
  """

  def execute("read_file", %{"path" => path} = input) do
    expanded = Path.expand(path)
    offset = Map.get(input, "offset", 1)
    limit = Map.get(input, "limit", 2000)

    case File.read(expanded) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total = length(lines)
        sliced =
          lines
          |> Enum.drop(max(0, offset - 1))
          |> Enum.take(limit)
          |> Enum.join("\n")
        {:ok, "(#{total} lines total, showing #{offset}-#{min(offset + limit - 1, total)})\n#{sliced}"}
      {:error, :enoent} -> {:error, "File not found: #{expanded}"}
      {:error, reason} -> {:error, "Read error: #{inspect(reason)}"}
    end
  end

  def execute("write_file", %{"path" => path, "content" => content}) do
    expanded = Path.expand(path)
    with :ok <- File.mkdir_p(Path.dirname(expanded)),
         :ok <- File.write(expanded, content) do
      {:ok, "Written #{byte_size(content)} bytes to #{expanded}"}
    else
      {:error, reason} -> {:error, "Write error: #{inspect(reason)}"}
    end
  end

  def execute("edit_file", %{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded = Path.expand(path)
    with {:ok, content} <- File.read(expanded) do
      if String.contains?(content, old) do
        new_content = String.replace(content, old, new, global: false)
        case File.write(expanded, new_content) do
          :ok -> {:ok, "Edit applied to #{expanded}"}
          {:error, r} -> {:error, inspect(r)}
        end
      else
        {:error, "old_string not found in file — no edit applied"}
      end
    else
      {:error, :enoent} -> {:error, "File not found: #{expanded}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  def execute("exec", %{"command" => cmd} = input) do
    workdir = Map.get(input, "workdir", System.get_env("HOME", "/tmp"))
    timeout = Map.get(input, "timeout_ms", 30_000)
    
    case System.cmd("sh", ["-c", cmd],
           cd: Path.expand(workdir),
           stderr_to_stdout: false,
           timeout: timeout) do
      {output, 0} -> {:ok, output}
      {output, code} -> {:ok, "[exit #{code}]\n#{output}"}
    end
  rescue
    e -> {:error, "exec failed: #{inspect(e)}"}
  end

  def execute("list_dir", %{"path" => path}) do
    expanded = Path.expand(path)
    case File.ls(expanded) do
      {:ok, entries} ->
        formatted =
          entries
          |> Enum.sort()
          |> Enum.map(fn name ->
            full = Path.join(expanded, name)
            if File.dir?(full), do: "#{name}/", else: name
          end)
          |> Enum.join("\n")
        {:ok, formatted}
      {:error, :enoent} -> {:error, "Directory not found: #{expanded}"}
      {:error, r} -> {:error, inspect(r)}
    end
  end

  def execute(name, _input), do: {:error, "Unknown tool: #{name}"}
end
```

**Files created:** `lib/kyber_beam/tool_executor.ex`  
**LOC:** ~90

---

### 4.4 Multi-Turn Tool Loop in LLM Plugin

This is the largest change. Replace the single-shot API call in `handle_llm_call/4` with a loop that:
1. Calls API with tools defined
2. If `stop_reason == "tool_use"` → extract tool calls, execute them, append `tool_result` blocks, loop
3. If `stop_reason == "end_turn"` → extract text content, emit `"llm.response"` delta, break

**New private function in `lib/kyber_beam/plugin/llm.ex`:**

```elixir
defp run_tool_loop(messages, system_prompt, auth_config, max_iterations \\ 10)

defp run_tool_loop(_messages, _system, _auth, 0), do: {:error, "tool loop limit reached"}

defp run_tool_loop(messages, system_prompt, auth_config, remaining) do
  params = %{
    "model" => @default_model,
    "max_tokens" => @default_max_tokens,
    "messages" => messages,
    "system" => system_prompt,
    "tools" => Kyber.Tools.definitions()
  }

  case call_api(auth_config, params) do
    {:ok, %{"stop_reason" => "tool_use", "content" => content_blocks}} ->
      # Collect all tool_use blocks
      tool_uses = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))
      
      # Build assistant turn with all content blocks
      assistant_msg = %{"role" => "assistant", "content" => content_blocks}
      
      # Execute each tool and build tool_result blocks
      tool_results =
        Enum.map(tool_uses, fn tu ->
          result = case Kyber.ToolExecutor.execute(tu["name"], tu["input"] || %{}) do
            {:ok, output} -> %{"type" => "tool_result", "tool_use_id" => tu["id"], "content" => output}
            {:error, err} -> %{"type" => "tool_result", "tool_use_id" => tu["id"], "content" => "Error: #{err}", "is_error" => true}
          end
          result
        end)
      
      user_result_msg = %{"role" => "user", "content" => tool_results}
      
      run_tool_loop(
        messages ++ [assistant_msg, user_result_msg],
        system_prompt,
        auth_config,
        remaining - 1
      )

    {:ok, %{"stop_reason" => "end_turn"} = response} ->
      {:ok, response}

    {:ok, response} ->
      # Any other stop reason — return as-is
      {:ok, response}

    {:error, _} = err ->
      err
  end
end
```

Replace the `call_api` call in `handle_llm_call/4` with `run_tool_loop/4`.

**Files changed:** `lib/kyber_beam/plugin/llm.ex`  
**LOC:** ~80

---

### 4.5 Test Strategy for Phase 4

```elixir
# test/kyber_beam/tool_executor_test.exs
# - read_file: existing file, nonexistent file, offset/limit
# - write_file: create new, overwrite existing, creates parent dirs
# - edit_file: successful edit, old_string not found
# - exec: simple command, non-zero exit, working directory
# - list_dir: existing dir, nonexistent dir, distinguishes files/dirs

# test/kyber_beam/plugin/llm_test.exs (additions)
# - session history round-trip: send message, get response, second message sees history
# - tool loop terminates on end_turn
# - tool loop executes tool and continues (mock ToolExecutor)
# - tool loop hits max_iterations and returns error
```

Use `Req.Test` stubs for the Anthropic API. The tool loop test should mock `call_api` to return `tool_use` on first call, `end_turn` on second.

**Estimated total Phase 4 LOC:** ~900  
**Dependencies:** None (self-contained fixes + new modules)

---

## Phase 5: Knowledge + Web Tools + Memory

**Target:** Stilgar can search his vault, fetch web pages, do semantic lookups, and inject relevant context into conversations automatically.

**Estimated LOC:** ~600  
**Complexity:** Medium  
**Shippable as:** Stilgar can answer questions with vault knowledge and fetch URLs on demand.

---

### 5.1 Wire Knowledge into LLM Context

`Kyber.Knowledge` (`lib/kyber_beam/knowledge.ex`) is started and populated but never consulted during LLM calls. The fix: before calling the API in `handle_llm_call`, query the vault for relevant L1 context and prepend it to the system prompt.

New helper in `lib/kyber_beam/plugin/llm.ex`:

```elixir
defp build_system_prompt(base_soul, chat_id) do
  # Load identity (L2 — full content)
  identity_context =
    case Kyber.Knowledge.get_tiered(Kyber.Knowledge, "identity/SOUL.md", :l2) do
      {:ok, note} -> note.body
      _ -> base_soul
    end

  # Today's memory note (L2)
  today = Date.to_string(Date.utc_today())
  memory_context =
    case Kyber.Knowledge.get_tiered(Kyber.Knowledge, "memory/#{today}.md", :l2) do
      {:ok, note} -> "\n\n## Today's Notes\n#{note.body}"
      _ -> ""
    end

  identity_context <> memory_context
end
```

Call this in `handle_llm_call` instead of bare `load_soul()`.

**Files changed:** `lib/kyber_beam/plugin/llm.ex`  
**LOC:** ~40

---

### 5.2 Knowledge Tools

Add to `lib/kyber_beam/tools.ex`:

```elixir
%{
  "name" => "memory_read",
  "description" => "Read a note from the knowledge vault by path (e.g. 'memory/2026-03-18.md', 'identity/SOUL.md').",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"},
      "tier" => %{"type" => "string", "enum" => ["l0", "l1", "l2"], "description" => "l0=title+tags, l1=frontmatter+first para, l2=full"}
    },
    "required" => ["path"]
  }
},
%{
  "name" => "memory_write",
  "description" => "Write or update a note in the knowledge vault.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "path" => %{"type" => "string"},
      "content" => %{"type" => "string"},
      "frontmatter" => %{"type" => "object"}
    },
    "required" => ["path", "content"]
  }
},
%{
  "name" => "memory_query",
  "description" => "Query the knowledge vault with filters.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "type" => %{"type" => "string", "description" => "Note type: identity | memory | people | projects | concepts | tools | decisions"},
      "tags" => %{"type" => "array", "items" => %{"type" => "string"}}
    }
  }
}
```

Add handlers in `lib/kyber_beam/tool_executor.ex`:

```elixir
def execute("memory_read", %{"path" => path} = input) do
  tier = Map.get(input, "tier", "l2") |> String.to_existing_atom()
  case Kyber.Knowledge.get_tiered(Kyber.Knowledge, path, tier) do
    {:ok, content} -> {:ok, inspect(content)}
    {:error, :not_found} -> {:error, "Note not found: #{path}"}
  end
end

def execute("memory_write", %{"path" => path, "content" => content} = input) do
  fm = Map.get(input, "frontmatter", %{})
  case Kyber.Knowledge.put_note(Kyber.Knowledge, path, fm, content) do
    :ok -> {:ok, "Note written: #{path}"}
    {:error, r} -> {:error, inspect(r)}
  end
end

def execute("memory_query", filters) do
  atom_filters = Enum.map(filters, fn {k, v} -> {String.to_existing_atom(k), v} end)
  notes = Kyber.Knowledge.query_notes(Kyber.Knowledge, atom_filters)
  summary = Enum.map(notes, fn n -> "#{n.path}: #{Map.get(n.frontmatter, "title", "(untitled)")}" end)
  {:ok, Enum.join(summary, "\n")}
end
```

**LOC:** ~80

---

### 5.3 Web Tools

Add to `lib/kyber_beam/tools.ex`:

```elixir
%{
  "name" => "web_fetch",
  "description" => "Fetch a URL and return its content as text/markdown.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "url" => %{"type" => "string"},
      "max_chars" => %{"type" => "integer", "description" => "Max characters to return (default 10000)"}
    },
    "required" => ["url"]
  }
}
```

Handler in `lib/kyber_beam/tool_executor.ex`:

```elixir
def execute("web_fetch", %{"url" => url} = input) do
  max_chars = Map.get(input, "max_chars", 10_000)
  case Req.get(url, receive_timeout: 15_000, redirect: true) do
    {:ok, %{status: 200, body: body}} when is_binary(body) ->
      truncated = String.slice(body, 0, max_chars)
      {:ok, truncated}
    {:ok, %{status: status}} ->
      {:error, "HTTP #{status}"}
    {:error, reason} ->
      {:error, inspect(reason)}
  end
end
```

For a real markdown extraction, this can later call an HTML→text converter. For now, raw body with truncation is sufficient.

**LOC:** ~40

---

### 5.4 Test Strategy for Phase 5

```elixir
# test/kyber_beam/plugin/llm_test.exs
# - build_system_prompt includes SOUL.md content
# - build_system_prompt includes today's memory note when present

# test/kyber_beam/tool_executor_test.exs (additions)
# - memory_read: existing note, nonexistent note, tier levels
# - memory_write: creates note, updates existing
# - memory_query: filter by type, filter by tags
# - web_fetch: mocked with Req.Test, 200 success, non-200 error
```

**Estimated total Phase 5 LOC:** ~600  
**Dependencies:** Phase 4 complete (tool infrastructure must exist)

---

## Phase 6: BEAM Introspection Tools

> **This is kyber-beam's unique differentiator.** No JS-based agent runtime — including OpenClaw — can do this. Node.js gives you `process.memoryUsage()` and that's about it. Stilgar runs on the BEAM, which exposes the entire runtime internals as queryable data. He can inspect his own process tree, message queues, supervision health, ETS tables, and reduction counts — in real time, via tool calls in a conversation.

**Target:** Stilgar can observe and reason about his own runtime. "My LLM plugin's message queue has 12 pending messages. The delta store is using 8MB. I have 3 supervisors with 14 total workers."

**Estimated LOC:** ~500  
**Complexity:** Low (mostly thin wrappers around existing BIFs — the BEAM does the heavy lifting)  
**Shippable as:** Stilgar can answer operational questions about himself and proactively report runtime health.

---

### 6.1 BEAM Introspection Module

New file: `lib/kyber_beam/introspection.ex`

This module wraps BEAM BIFs into clean, JSON-serializable output suitable for LLM tool results.

```elixir
defmodule Kyber.Introspection do
  @moduledoc """
  BEAM runtime introspection for Stilgar.
  
  Wraps :erlang BIFs and OTP inspection functions into clean maps
  suitable for tool results. All functions return plain data (no PIDs,
  no atoms in values) so results serialize cleanly to JSON strings.
  
  This is what separates kyber-beam from every Node.js-based agent:
  Stilgar can look at his own guts.
  """

  @doc """
  System-level memory breakdown in bytes.
  
  Returns total, processes, system, atom, binary, code, ets.
  """
  def memory_summary do
    mem = :erlang.memory()
    %{
      total_mb: round(mem[:total] / 1_048_576 * 100) / 100,
      processes_mb: round(mem[:processes] / 1_048_576 * 100) / 100,
      system_mb: round(mem[:system] / 1_048_576 * 100) / 100,
      atom_mb: round(mem[:atom] / 1_048_576 * 100) / 100,
      binary_mb: round(mem[:binary] / 1_048_576 * 100) / 100,
      ets_mb: round(mem[:ets] / 1_048_576 * 100) / 100,
      code_mb: round(mem[:code] / 1_048_576 * 100) / 100
    }
  end

  @doc """
  System info summary: schedulers, uptime, process/port/atom counts.
  """
  def system_info do
    {uptime_ms, _} = :erlang.statistics(:wall_clock)
    %{
      schedulers: :erlang.system_info(:schedulers),
      schedulers_online: :erlang.system_info(:schedulers_online),
      process_count: :erlang.system_info(:process_count),
      process_limit: :erlang.system_info(:process_limit),
      port_count: :erlang.system_info(:port_count),
      atom_count: :erlang.system_info(:atom_count),
      atom_limit: :erlang.system_info(:atom_limit),
      uptime_seconds: div(uptime_ms, 1000),
      otp_release: to_string(:erlang.system_info(:otp_release)),
      erts_version: to_string(:erlang.system_info(:version))
    }
  end

  @doc """
  Top N processes by memory usage. Returns pid-string, name, memory_kb, message_queue_len.
  """
  def top_processes(n \\ 20) do
    :erlang.processes()
    |> Enum.map(fn pid ->
      info = Process.info(pid, [:registered_name, :memory, :message_queue_len, :reductions, :current_function])
      if info do
        name = case info[:registered_name] do
          [] -> inspect(pid)
          name -> to_string(name)
        end
        {cf_m, cf_f, cf_a} = info[:current_function] || {:unknown, :unknown, 0}
        %{
          pid: inspect(pid),
          name: name,
          memory_kb: round(info[:memory] / 1024 * 10) / 10,
          message_queue_len: info[:message_queue_len],
          reductions: info[:reductions],
          current_function: "#{cf_m}.#{cf_f}/#{cf_a}"
        }
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_kb, :desc)
    |> Enum.take(n)
  end

  @doc """
  Inspect a named process: memory, queue length, status, current function, links.
  """
  def inspect_process(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, "Process #{name} not found"}
      pid -> inspect_pid(pid)
    end
  end

  def inspect_pid(pid) when is_pid(pid) do
    keys = [:registered_name, :memory, :message_queue_len, :reductions,
            :status, :current_function, :links, :trap_exit, :heap_size]
    case Process.info(pid, keys) do
      nil -> {:error, "Process #{inspect(pid)} not alive"}
      info ->
        {cf_m, cf_f, cf_a} = info[:current_function] || {:unknown, :unknown, 0}
        %{
          pid: inspect(pid),
          name: case info[:registered_name] do [] -> nil; n -> to_string(n) end,
          memory_kb: round(info[:memory] / 1024 * 10) / 10,
          message_queue_len: info[:message_queue_len],
          reductions: info[:reductions],
          status: to_string(info[:status]),
          current_function: "#{cf_m}.#{cf_f}/#{cf_a}",
          link_count: length(info[:links] || []),
          trap_exit: info[:trap_exit],
          heap_size_words: info[:heap_size]
        }
    end
  end

  @doc """
  Get GenServer internal state via :sys.get_state/1.
  
  Works on any named GenServer. Returns the state as an inspected string
  (not all states are JSON-safe, so inspect is safer than Jason.encode).
  """
  def genserver_state(name) when is_atom(name) do
    try do
      state = :sys.get_state(name, 5_000)
      {:ok, inspect(state, limit: 50, pretty: true)}
    catch
      :exit, {:timeout, _} -> {:error, "timeout — process may be busy"}
      :exit, {:noproc, _} -> {:error, "process #{name} not running"}
    end
  end

  @doc """
  Walk a supervisor's children. Returns name, pid-or-status, type, module.
  Optionally recurse into child supervisors.
  """
  def supervision_tree(supervisor, depth \\ 2) do
    try do
      children = Supervisor.which_children(supervisor)
      counts = Supervisor.count_children(supervisor)
      %{
        supervisor: to_string(supervisor),
        counts: %{
          active: counts.active,
          workers: counts.workers,
          supervisors: counts.supervisors,
          specs: counts.specs
        },
        children: Enum.map(children, fn {id, pid_or_status, type, mods} ->
          child = %{
            id: inspect(id),
            type: to_string(type),
            module: inspect(List.first(mods) || :unknown),
            status: inspect(pid_or_status)
          }
          if depth > 1 && type == :supervisor && is_pid(pid_or_status) do
            Map.put(child, :children, supervision_tree(pid_or_status, depth - 1))
          else
            child
          end
        end)
      }
    catch
      :exit, _ -> {:error, "#{supervisor} not running or not a supervisor"}
    end
  end

  @doc """
  ETS table summary: all tables with name, size, memory, type.
  """
  def ets_summary do
    :ets.all()
    |> Enum.map(fn table ->
      try do
        info = :ets.info(table)
        %{
          id: inspect(table),
          name: to_string(info[:name]),
          size: info[:size],
          memory_kb: round(info[:memory] * :erlang.system_info(:wordsize) / 1024 * 10) / 10,
          type: to_string(info[:type]),
          owner: inspect(info[:owner])
        }
      rescue
        _ -> nil
      end
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.memory_kb, :desc)
  end

  @doc """
  Stats for a specific ETS table: size, memory, sample of keys.
  """
  def ets_inspect(table_name) when is_atom(table_name) do
    try do
      info = :ets.info(table_name)
      sample_keys =
        :ets.tab2list(table_name)
        |> Enum.take(5)
        |> Enum.map(fn
          {k, _v} -> inspect(k)
          other -> inspect(other)
        end)
      %{
        name: to_string(info[:name]),
        size: info[:size],
        memory_kb: round(info[:memory] * :erlang.system_info(:wordsize) / 1024 * 10) / 10,
        type: to_string(info[:type]),
        sample_keys: sample_keys
      }
    rescue
      _ -> {:error, "Table #{table_name} not found"}
    end
  end

  @doc """
  Delta store stats: total deltas, breakdown by kind, storage file size.
  """
  def delta_store_stats do
    store = Kyber.Core.Store
    try do
      all_deltas = Kyber.Delta.Store.query(store, [])
      by_kind =
        all_deltas
        |> Enum.group_by(& &1.kind)
        |> Enum.map(fn {kind, deltas} -> {kind, length(deltas)} end)
        |> Enum.sort_by(fn {_, count} -> count end, :desc)
        |> Map.new()

      store_path = Path.join(System.get_env("KYBER_DATA_DIR", "priv/data"), "deltas.jsonl")
      file_size_kb =
        case File.stat(store_path) do
          {:ok, %{size: size}} -> round(size / 1024 * 10) / 10
          _ -> nil
        end

      %{
        total_deltas: length(all_deltas),
        by_kind: by_kind,
        file_size_kb: file_size_kb,
        store_path: store_path
      }
    catch
      _ -> {:error, "Delta store not accessible"}
    end
  end

  @doc """
  Scheduler utilization over a 1-second sample window.
  Returns per-scheduler wall/active time percentages.
  """
  def scheduler_utilization do
    sample = :scheduler.sample_all()
    Process.sleep(1_000)
    utilization = :scheduler.utilization(1, sample)
    Enum.map(utilization, fn {type, id, active, total, _} ->
      pct = if total > 0, do: round(active / total * 1000) / 10, else: 0.0
      %{type: to_string(type), id: id, utilization_pct: pct}
    end)
  end

  @doc """
  I/O stats: bytes in/out since VM start.
  """
  def io_stats do
    {{:input, bytes_in}, {:output, bytes_out}} = :erlang.statistics(:io)
    %{
      input_mb: round(bytes_in / 1_048_576 * 100) / 100,
      output_mb: round(bytes_out / 1_048_576 * 100) / 100
    }
  end

  @doc """
  Trigger GC on a named process (or all processes if :all).
  Returns memory before/after for the targeted process.
  """
  def gc(name) when is_atom(name) do
    case Process.whereis(name) do
      nil -> {:error, "Process #{name} not found"}
      pid ->
        before_mem = Process.info(pid, :memory)[:memory]
        :erlang.garbage_collect(pid)
        after_mem = Process.info(pid, :memory)[:memory]
        %{
          process: to_string(name),
          before_kb: round(before_mem / 1024 * 10) / 10,
          after_kb: round(after_mem / 1024 * 10) / 10,
          freed_kb: round((before_mem - after_mem) / 1024 * 10) / 10
        }
    end
  end

  def gc(:all) do
    before_total = :erlang.memory(:total)
    :erlang.processes() |> Enum.each(&:erlang.garbage_collect/1)
    after_total = :erlang.memory(:total)
    %{
      scope: "all_processes",
      before_mb: round(before_total / 1_048_576 * 100) / 100,
      after_mb: round(after_total / 1_048_576 * 100) / 100,
      freed_mb: round((before_total - after_total) / 1_048_576 * 100) / 100
    }
  end

  @doc """
  Hot reload a module by name. Returns :ok or error.
  """
  def reload_module(module_name) when is_atom(module_name) do
    case IEx.Helpers.r(module_name) do
      {:reloaded, _, _} -> {:ok, "#{module_name} reloaded"}
      _ ->
        # Fallback: direct beam reload
        case :code.purge(module_name) do
          _ ->
            case :code.load_file(module_name) do
              {:module, ^module_name} -> {:ok, "#{module_name} reloaded"}
              {:error, reason} -> {:error, inspect(reason)}
            end
        end
    end
  rescue
    e -> {:error, "reload failed: #{inspect(e)}"}
  end

  @doc """
  Active ports: counts and a list of port details (driver, connected process).
  """
  def port_info do
    ports = Port.list()
    details =
      ports
      |> Enum.take(20)
      |> Enum.map(fn port ->
        info = Port.info(port)
        %{
          port: inspect(port),
          name: to_string(info[:name] || ""),
          connected: inspect(info[:connected]),
          links: length(info[:links] || [])
        }
      end)
    %{total_ports: length(ports), sample: details}
  end

  @doc """
  Processes with message queues over the threshold. Useful for detecting backpressure.
  """
  def queue_health(threshold \\ 5) do
    :erlang.processes()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:registered_name, :message_queue_len]) do
        nil -> []
        info when info[:message_queue_len] >= threshold ->
          name = case info[:registered_name] do [] -> inspect(pid); n -> to_string(n) end
          [%{pid: inspect(pid), name: name, queue_len: info[:message_queue_len]}]
        _ -> []
      end
    end)
    |> Enum.sort_by(& &1.queue_len, :desc)
  end
end
```

**Files created:** `lib/kyber_beam/introspection.ex`  
**LOC:** ~220

---

### 6.2 BEAM Introspection Tools

Add to `lib/kyber_beam/tools.ex`:

```elixir
# --- BEAM Introspection (unique to kyber-beam) ---
%{
  "name" => "beam_memory",
  "description" => "BEAM VM memory breakdown: total, processes, ETS, binary, code, atom. All in MB.",
  "input_schema" => %{"type" => "object", "properties" => %{}}
},
%{
  "name" => "beam_system",
  "description" => "BEAM system info: scheduler count, process/atom/port counts, uptime, OTP version.",
  "input_schema" => %{"type" => "object", "properties" => %{}}
},
%{
  "name" => "beam_processes",
  "description" => "Top processes by memory usage. Returns pid, name, memory_kb, message_queue_len, reductions.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "limit" => %{"type" => "integer", "description" => "Max processes to return (default 20)"}
    }
  }
},
%{
  "name" => "beam_inspect_process",
  "description" => "Inspect a named BEAM process: memory, queue length, status, current function.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "description" => "Registered process name, e.g. 'Kyber.Plugin.LLM'"}
    },
    "required" => ["name"]
  }
},
%{
  "name" => "beam_genserver_state",
  "description" => "Inspect a GenServer's internal state via :sys.get_state/1. Works on any named GenServer including Kyber plugins.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "name" => %{"type" => "string", "description" => "GenServer registered name, e.g. 'Kyber.Session'"}
    },
    "required" => ["name"]
  }
},
%{
  "name" => "beam_supervision_tree",
  "description" => "Walk the supervision tree of a supervisor. Shows children counts, PIDs, types.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "supervisor" => %{"type" => "string", "description" => "Supervisor name, e.g. 'Kyber.Core' or 'KyberBeam.Supervisor'"},
      "depth" => %{"type" => "integer", "description" => "Recursion depth (default 2)"}
    },
    "required" => ["supervisor"]
  }
},
%{
  "name" => "beam_ets",
  "description" => "ETS table summary: all tables with name, row count, memory usage, type.",
  "input_schema" => %{"type" => "object", "properties" => %{}}
},
%{
  "name" => "beam_ets_inspect",
  "description" => "Inspect a specific ETS table: size, memory, sample keys.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "table" => %{"type" => "string", "description" => "Table name atom, e.g. 'Kyber.Session.Sessions'"}
    },
    "required" => ["table"]
  }
},
%{
  "name" => "beam_deltas",
  "description" => "Delta store stats: total delta count, breakdown by kind, file size.",
  "input_schema" => %{"type" => "object", "properties" => %{}}
},
%{
  "name" => "beam_queue_health",
  "description" => "Find processes with backed-up message queues (default threshold: 5). Detects backpressure.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "threshold" => %{"type" => "integer", "description" => "Min queue length to report (default 5)"}
    }
  }
},
%{
  "name" => "beam_gc",
  "description" => "Trigger garbage collection on a named process or all processes. Returns memory freed.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "target" => %{"type" => "string", "description" => "Process name or 'all'"}
    },
    "required" => ["target"]
  }
},
%{
  "name" => "beam_reload_module",
  "description" => "Hot-reload an Elixir module without restarting the VM.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "module" => %{"type" => "string", "description" => "Module name, e.g. 'Kyber.Reducer'"}
    },
    "required" => ["module"]
  }
},
%{
  "name" => "beam_io_stats",
  "description" => "VM-level I/O statistics: total bytes in/out since start.",
  "input_schema" => %{"type" => "object", "properties" => %{}}
},
%{
  "name" => "beam_ports",
  "description" => "Port/socket inspection: active ports, driver names, connected processes.",
  "input_schema" => %{"type" => "object", "properties" => %{}}
}
```

Add handlers in `lib/kyber_beam/tool_executor.ex`:

```elixir
def execute("beam_memory", _input) do
  {:ok, Kyber.Introspection.memory_summary() |> format_map()}
end

def execute("beam_system", _input) do
  {:ok, Kyber.Introspection.system_info() |> format_map()}
end

def execute("beam_processes", input) do
  limit = Map.get(input, "limit", 20)
  results = Kyber.Introspection.top_processes(limit)
  {:ok, format_list(results)}
end

def execute("beam_inspect_process", %{"name" => name}) do
  atom = String.to_existing_atom(name)
  case Kyber.Introspection.inspect_process(atom) do
    {:error, msg} -> {:error, msg}
    info -> {:ok, format_map(info)}
  end
rescue
  ArgumentError -> {:error, "Unknown process name: #{name}"}
end

def execute("beam_genserver_state", %{"name" => name}) do
  atom = String.to_existing_atom(name)
  case Kyber.Introspection.genserver_state(atom) do
    {:ok, state_str} -> {:ok, state_str}
    {:error, msg} -> {:error, msg}
  end
rescue
  ArgumentError -> {:error, "Unknown module: #{name}"}
end

def execute("beam_supervision_tree", %{"supervisor" => sup} = input) do
  depth = Map.get(input, "depth", 2)
  atom = String.to_existing_atom(sup)
  case Kyber.Introspection.supervision_tree(atom, depth) do
    {:error, msg} -> {:error, msg}
    tree -> {:ok, format_map(tree)}
  end
rescue
  ArgumentError -> {:error, "Unknown supervisor: #{sup}"}
end

def execute("beam_ets", _input) do
  {:ok, Kyber.Introspection.ets_summary() |> format_list()}
end

def execute("beam_ets_inspect", %{"table" => table}) do
  atom = String.to_existing_atom(table)
  case Kyber.Introspection.ets_inspect(atom) do
    {:error, msg} -> {:error, msg}
    info -> {:ok, format_map(info)}
  end
rescue
  ArgumentError -> {:error, "Unknown table: #{table}"}
end

def execute("beam_deltas", _input) do
  case Kyber.Introspection.delta_store_stats() do
    {:error, msg} -> {:error, msg}
    stats -> {:ok, format_map(stats)}
  end
end

def execute("beam_queue_health", input) do
  threshold = Map.get(input, "threshold", 5)
  results = Kyber.Introspection.queue_health(threshold)
  if results == [] do
    {:ok, "All message queues healthy (all below threshold #{threshold})"}
  else
    {:ok, "#{length(results)} processes with queues >= #{threshold}:\n#{format_list(results)}"}
  end
end

def execute("beam_gc", %{"target" => "all"}) do
  {:ok, Kyber.Introspection.gc(:all) |> format_map()}
end

def execute("beam_gc", %{"target" => name}) do
  atom = String.to_existing_atom(name)
  case Kyber.Introspection.gc(atom) do
    {:error, msg} -> {:error, msg}
    result -> {:ok, format_map(result)}
  end
rescue
  ArgumentError -> {:error, "Unknown process: #{name}"}
end

def execute("beam_reload_module", %{"module" => mod}) do
  atom = String.to_existing_atom("Elixir." <> mod)
  Kyber.Introspection.reload_module(atom)
rescue
  ArgumentError -> {:error, "Unknown module: #{mod}"}
end

def execute("beam_io_stats", _input) do
  {:ok, Kyber.Introspection.io_stats() |> format_map()}
end

def execute("beam_ports", _input) do
  {:ok, Kyber.Introspection.port_info() |> format_map()}
end

# Formatting helpers
defp format_map(map) when is_map(map) do
  map
  |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
  |> Enum.join("\n")
end

defp format_list(list) when is_list(list) do
  list
  |> Enum.with_index(1)
  |> Enum.map(fn {item, i} -> "#{i}. #{format_map(item)}" end)
  |> Enum.join("\n\n")
end
```

**Files changed:** `lib/kyber_beam/tools.ex`, `lib/kyber_beam/tool_executor.ex`  
**LOC:** ~200 (tools) + ~120 (executor handlers)

---

### 6.3 What This Enables

Concrete conversations Stilgar can now have:

> "How much memory is the delta store using?"  
> → `beam_ets_inspect("Kyber.Core.Store")` → "14.2KB, 387 rows"

> "Is anything backing up?"  
> → `beam_queue_health(3)` → "All clear" or "Kyber.Plugin.LLM has 8 pending messages"

> "What's your process count?"  
> → `beam_system()` → "47 processes, 10 schedulers, uptime 3h 22m"

> "Can you reload the reducer without restarting?"  
> → `beam_reload_module("Kyber.Reducer")` → "Kyber.Reducer reloaded"

> "Show me your supervision tree"  
> → `beam_supervision_tree("KyberBeam.Supervisor")` → full tree with counts

> "What's your LLM plugin actually holding in state right now?"  
> → `beam_genserver_state("Kyber.Plugin.LLM")` → inspected state map

**No JS agent can do any of this.** This isn't a footnote — it's a design moat. Stilgar is a BEAM process that can see himself.

---

### 6.4 Test Strategy for Phase 6

```elixir
# test/kyber_beam/introspection_test.exs
# - memory_summary: returns map with total_mb, all keys present, values > 0
# - system_info: process_count > 0, schedulers > 0, uptime_seconds > 0
# - top_processes: returns list, sorted by memory desc, all have required keys
# - inspect_process: Kyber.Session exists → returns info; :nonexistent → error
# - genserver_state: Kyber.Session returns string; nonexistent → error
# - supervision_tree: KyberBeam.Supervisor returns map with children list
# - ets_summary: returns list, Kyber.Session.Sessions table present
# - queue_health: returns list (may be empty, that's fine)
# - gc: single process returns before/after/freed; :all returns scope "all_processes"
# - delta_store_stats: total_deltas is integer, by_kind is map

# test/kyber_beam/tool_executor_test.exs (additions)
# - beam_* tools all exercise the Introspection module
# - beam_inspect_process with unknown atom raises ArgumentError → {:error, ...}
```

**Estimated total Phase 6 LOC:** ~500  
**Dependencies:** Phase 4 (tool infrastructure must exist)

---

## Phase 7: Heartbeat + Proactive Behavior

**Target:** Stilgar can initiate conversation, not just respond. The Cron system fires heartbeats that trigger LLM calls, and the responses actually go somewhere (Myk's DMs).

**Estimated LOC:** ~300  
**Complexity:** Medium  

---

### 7.1 Fix the Heartbeat Routing Problem

The current flow: `cron.fired` → reducer → `:llm_call` effect with `origin: {:cron, "heartbeat"}` → LLM plugin calls API → `llm.response` delta with `origin: {:cron, "heartbeat"}` → reducer sees no `channel_id` → no `:send_message` effect emitted → response disappears.

**Fix:** The heartbeat cron job needs a target channel baked in. Two options:

**Option A (simpler):** Configure `HEARTBEAT_CHANNEL_ID` env var. When the reducer sees `cron.fired` with `job_name: "heartbeat"`, emit the `:llm_call` with a `target_channel` in the payload:

In `lib/kyber_beam/reducer.ex`, update the `"cron.fired"` clause:

```elixir
def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "cron.fired"} = delta) do
  job_name = Map.get(delta.payload, "job_name", "")
  
  effects =
    if job_name == "heartbeat" do
      channel_id = System.get_env("HEARTBEAT_CHANNEL_ID")
      if channel_id do
        [%{
          type: :llm_call,
          delta_id: delta.id,
          payload: %{
            "text" => load_heartbeat_prompt(),
            "target_channel" => channel_id
          },
          origin: {:cron, "heartbeat", channel_id}  # encode channel in origin
        }]
      else
        []
      end
    else
      []
    end
  
  {state, effects}
end
```

Update the `"llm.response"` clause to also check `origin` for the cron heartbeat pattern:

```elixir
def reduce(%Kyber.State{} = state, %Kyber.Delta{kind: "llm.response"} = delta) do
  content = Map.get(delta.payload, "content", "")
  
  channel_id =
    case delta.origin do
      {:channel, "discord", cid, _} -> cid
      {:cron, "heartbeat", cid} -> cid   # <-- new
      _ -> Map.get(delta.payload, "channel_id")
    end
  
  # rest unchanged
end
```

**Option B (better long-term):** Add a `Kyber.Cron.add_job` call at startup with a metadata map containing `target_channel`, and propagate that metadata through the `"cron.fired"` delta payload. Allows per-job routing.

Implement Option A for now, document Option B as the upgrade path.

**Files changed:** `lib/kyber_beam/reducer.ex`  
**LOC:** ~30

---

### 7.2 Proactive Discord Message Effect

Add a new effect type `:dm_user` and `:post_channel` to complement `:send_message`. Currently `:send_message` handles replies, but proactive messages need a distinct path (and may carry different formatting — no `reply_to`, different rate limits).

In `lib/kyber_beam/plugin/discord.ex`, add to `register_send_handler`:

```elixir
def register_proactive_handler(core, token) do
  handler = fn effect ->
    channel_id = get_in(effect, [:payload, "channel_id"])
    content = get_in(effect, [:payload, "content"])
    if channel_id && content, do: send_message(token, channel_id, content)
  end
  Kyber.Core.register_effect_handler(core, :post_channel, handler)
end
```

**Files changed:** `lib/kyber_beam/plugin/discord.ex`, `lib/kyber_beam/reducer.ex`  
**LOC:** ~60

---

### 7.3 Heartbeat System Prompt

Add `lib/kyber_beam/heartbeat.ex` — a small module that builds the heartbeat prompt from current state:

```elixir
defmodule Kyber.Heartbeat do
  def build_prompt do
    today = Date.to_string(Date.utc_today())
    hour = DateTime.utc_now().hour
    
    """
    [HEARTBEAT — #{DateTime.utc_now() |> DateTime.to_string()}]
    
    This is a scheduled heartbeat check-in. You are running as Stilgar on kyber-beam.
    Review your state and decide if there's anything worth proactively sharing.
    
    Current time: #{hour}:00 UTC
    Today's memory file: memory/#{today}.md (check if anything needs noting)
    
    Your options:
    1. Send a brief message if something is worth noting
    2. Stay silent (respond with exactly: HEARTBEAT_OK)
    
    Respect late hours (23:00-08:00 UTC). Don't spam. Only speak if there's genuine value.
    """
  end
end
```

**Files created:** `lib/kyber_beam/heartbeat.ex`  
**LOC:** ~30

---

### 7.4 Wire Familiard

Add `Kyber.Familiard` to `lib/kyber_beam/application.ex` children list. It's fully implemented but orphaned:

```elixir
{Kyber.Familiard,
 name: Kyber.Familiard,
 core: Kyber.Core}
```

**Files changed:** `lib/kyber_beam/application.ex`  
**LOC:** ~5

---

### 7.5 Test Strategy for Phase 7

```elixir
# test/kyber_beam/reducer_test.exs (additions)
# - cron.fired with job_name "heartbeat" and HEARTBEAT_CHANNEL_ID set → emits :llm_call with channel
# - cron.fired with job_name "heartbeat" and no env var → emits nothing
# - llm.response with {:cron, "heartbeat", channel_id} origin → emits :send_message

# Integration: set HEARTBEAT_CHANNEL_ID in test env, trigger cron, verify Discord effect fires
```

**Estimated total Phase 7 LOC:** ~300  
**Dependencies:** Phase 4 (tool loop), Phase 5 optional (Knowledge prompt context)

---

## Phase 8: Rich Discord Interactions

**Target:** Stilgar can react to messages, reply in threads, send embeds, and handle rate limiting gracefully.

**Estimated LOC:** ~500  
**Complexity:** Medium  
**Shippable as:** Stilgar feels like a native Discord bot, not just a text pipe.

---

### 8.1 Rich Discord Effect Types

Add to `lib/kyber_beam/plugin/discord.ex`:
- `:react_message` — add emoji reaction to a message
- `:create_thread` — create a thread on a message
- `:send_embed` — send a rich embed
- `:send_reply` — send a reply referencing a message_id

Add to `lib/kyber_beam/tools.ex`:
- `discord_react` — add a reaction to the current message
- `discord_thread` — create a thread
- `discord_send` — send a message to any accessible channel

The `message_id` and `channel_id` from the original `message.received` delta need to flow through the entire pipeline so tool calls can reference the triggering message. Wire `message_id` into delta payload in `build_message_delta/1` (already done — it's there as `"message_id"`), and make sure it survives into the LLM effect.

---

### 8.2 Response Chunking

Discord's 2000-character limit requires chunking long responses. Add to `lib/kyber_beam/plugin/discord.ex`:

```elixir
defp chunk_and_send(token, channel_id, content) when byte_size(content) > 1900 do
  content
  |> String.graphemes()
  |> Enum.chunk_every(1900)
  |> Enum.map(&Enum.join/1)
  |> Enum.each(fn chunk ->
    send_message(token, channel_id, chunk)
    Process.sleep(500)  # stay under rate limit
  end)
end

defp chunk_and_send(token, channel_id, content) do
  send_message(token, channel_id, content)
end
```

Replace the bare `send_message` call in the `:send_message` handler with `chunk_and_send`.

---

### 8.3 Rate Limiting

Add a simple token-bucket rate limiter in `lib/kyber_beam/rate_limiter.ex`. Discord allows ~5 messages/5s per channel. Store per-channel send timestamps in ETS, check before sending.

---

### 8.4 Streaming Responses (Stretch)

Replace the blocking `Req.post` in `call_api` with a streaming variant using `Req`'s `into: :self` pattern. Emit incremental `"llm.chunk"` deltas that the Discord plugin accumulates and edits into a single message using Discord's message edit API. Significant complexity — treat as optional for this phase.

**Estimated total Phase 8 LOC:** ~500  
**Dependencies:** Phase 4 required

---

## Phase 9: Advanced Parity

**Target:** Everything else OpenClaw has that Stilgar still lacks.

**Estimated LOC:** ~800  
**Complexity:** High  

---

### 9.1 Context Window Management

Track token usage from `response["usage"]` (already available in the API response). Store cumulative token usage per `chat_id` in `Kyber.Session`. When approaching limit (configurable threshold, e.g. 180K tokens for Claude Sonnet's 200K context):

1. Emit a `"session.compacting"` delta
2. Summarize the conversation with a dedicated LLM call: "Summarize this conversation into a dense context block"
3. Replace the session history with the summary as a single system-role block
4. Continue with fresh history

Module: `lib/kyber_beam/session_compactor.ex`

---

### 9.2 Sub-Agent Spawning

Stilgar spawns sub-agents by starting additional `Kyber.Core` supervisor instances with their own session, state, and plugin manager. The parent agent's tool loop receives results via a `Task` and injects them as `tool_result` blocks.

Tool: `spawn_agent` — takes a task description, starts an isolated pipeline, returns the result.

This is the most complex feature. The BEAM's supervision model makes it cleaner than OpenClaw's approach (which uses separate processes via `sessions_spawn`). Each sub-agent is just another subtree under the main supervisor.

---

### 9.3 Error Recovery + Retry

Wrap the `run_tool_loop` API call with exponential backoff on 529/rate-limit responses. Add a `Retry` helper module:

```elixir
defmodule Kyber.Retry do
  def with_backoff(fun, max_attempts \\ 3, base_ms \\ 1_000) do
    # exponential backoff with jitter
  end
end
```

Call `Retry.with_backoff(fn -> call_api(auth, params) end)` in the tool loop.

---

### 9.4 Model Selection + Fallback

Add `model` field to `:llm_call` effects. Default to Sonnet, fall back to Haiku on rate limit (429). Expose a `set_model` tool:

```elixir
%{
  "name" => "set_model",
  "description" => "Change the LLM model for this conversation.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "model" => %{"type" => "string", "enum" => ["claude-sonnet-4-20250514", "claude-haiku-4-20250514"]}
    },
    "required" => ["model"]
  }
}
```

Store per-session model preference in `Kyber.Session`.

---

### 9.5 Image Analysis Tool

Add `analyze_image` tool:

```elixir
%{
  "name" => "analyze_image",
  "description" => "Analyze an image file or URL using Claude's vision capability.",
  "input_schema" => %{
    "type" => "object",
    "properties" => %{
      "source" => %{"type" => "string", "description" => "File path or URL"},
      "prompt" => %{"type" => "string", "description" => "What to look for"}
    },
    "required" => ["source", "prompt"]
  }
}
```

Handler: Load image as base64, build a vision API call with `image/jpeg` content block. This is a simple extension of the existing `call_api` mechanism.

**Estimated total Phase 9 LOC:** ~800  
**Dependencies:** All prior phases

---

## Dependency Graph

```
Phase 4 (history + basic tools + tool loop)
    │
    ├── Phase 5 (knowledge + web tools)
    │       └── requires Phase 4 tool infrastructure
    │
    ├── Phase 6 (BEAM introspection)
    │       └── requires Phase 4 tool infrastructure
    │           (can be built in parallel with Phase 5)
    │
    ├── Phase 7 (heartbeat + proactive)
    │       └── requires Phase 4 (LLM call path)
    │           Phase 5 optional (richer heartbeat context)
    │
    └── Phase 8 (rich Discord)
            └── requires Phase 4
            Phase 9 requires all of the above
```

Phases 5, 6, and 7 can be developed in parallel after Phase 4 ships. They touch different files.

---

## LOC Summary

| Phase | What | LOC | Complexity |
|-------|------|-----|------------|
| 4 | Conversation history fix + basic tools + tool loop | ~900 | High |
| 5 | Knowledge + web tools | ~600 | Medium |
| 6 | BEAM introspection tools | ~500 | Low-Medium |
| 7 | Heartbeat + proactive behavior | ~300 | Medium |
| 8 | Rich Discord interactions | ~500 | Medium |
| 9 | Advanced parity (compaction, sub-agents, retry) | ~800 | High |
| **Total** | | **~3,600** | |

Phase 4 is the critical path. Everything else is additive.

---

## What Stilgar Has That OpenClaw Never Will

OpenClaw runs on Node.js. The BEAM is a fundamentally different substrate. These are permanent advantages:

1. **Process introspection at any granularity** — from the whole VM down to a single GenServer's heap
2. **Hot code reload** — change Stilgar's behavior without restarting him, without losing conversation state
3. **Message queue visibility** — detect backpressure in real time, self-diagnose slowdowns
4. **Supervision tree as first-class data** — the hierarchy of his own components is queryable
5. **ETS as transparent memory** — his session table, delta store, and any other ETS table are directly inspectable
6. **True concurrent sub-agents** — BEAM schedulers, not event loop tricks
7. **Distribution** — `Kyber.Distribution` already exists; Stilgar can spread across nodes
8. **Fault isolation by design** — one plugin crashing doesn't take down the whole agent

The BEAM introspection tools in Phase 6 are the interface to all of this. They turn runtime observability into a conversational capability.

---

*Engineering document. Commit this alongside whatever phase is currently in progress.*
*Next action: start Phase 4.1 (fix Session writes in `lib/kyber_beam/plugin/llm.ex`).*
