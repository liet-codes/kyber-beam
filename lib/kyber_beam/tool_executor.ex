defmodule Kyber.ToolExecutor do
  @moduledoc """
  Executes tool calls by name. Pure functions — no GenServer, no state.

  All handlers return `{:ok, result_string}` or `{:error, reason_string}`.
  The result string goes directly into the `tool_result` content block sent
  back to the LLM.

  Phase 4 tools: read_file, write_file, edit_file, exec, list_dir
  Phase 5 tools: memory_read, memory_write, memory_list, web_fetch

  ## Security

  - write_file and edit_file are restricted to @allowed_write_roots.
  - memory_write is restricted to the vault path.
  - exec commands are logged before execution (no denylist; personal machine).
  - exec output is truncated to 100KB to prevent OOM / API rejections.
  - web_fetch responses are truncated to 50KB.
  """

  require Logger

  # Strict allowlist for the exec tool.
  # Only these command stems are permitted — anything else is rejected.
  # This prevents LLM prompt injection from running arbitrary shell commands.
  @allowed_exec_commands ~w(ls cat grep mix git node elixir erl head tail wc sort uniq find file du df date cd mkdir touch cp mv chmod)

  # NOTE: @allowed_write_roots, @allowed_read_roots, and @vault_path are
  # intentionally defined as private functions below (not module attributes)
  # so that Path.expand and System.tmp_dir! are evaluated at runtime against
  # the actual $HOME, not the $HOME of the build environment.
  # See: Architecture Audit M3.
  # NOTE: web_fetch truncation now handled by Kyber.Tools.WebFetch (max_chars option).

  # NOTE: SSRF blocked hosts moved to Kyber.Tools.WebFetch module.

  @doc """
  Execute a tool by name with its input map.

  Returns `{:ok, result_string}` or `{:error, reason_string}`.
  """
  @spec execute(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}

  def execute("read_file", %{"path" => path} = input) do
    expanded = Path.expand(path)

    unless read_path_allowed?(expanded) do
      {:error, "path not in allowed read directories: #{expanded}"}
    else
      offset = Map.get(input, "offset", 1)
      limit = Map.get(input, "limit", 2000)

      case File.read(expanded) do
        {:ok, content} ->
          lines = String.split(content, "\n")
          total = length(lines)
          start_idx = max(0, offset - 1)

          sliced =
            lines
            |> Enum.drop(start_idx)
            |> Enum.take(limit)
            |> Enum.join("\n")

          end_line = min(offset + limit - 1, total)
          {:ok, "(#{total} lines total, showing #{offset}-#{end_line})\n#{sliced}"}

        {:error, :enoent} ->
          {:error, "File not found: #{expanded}"}

        {:error, reason} ->
          {:error, "Read error: #{inspect(reason)}"}
      end
    end
  end

  def execute("write_file", %{"path" => path, "content" => content}) do
    expanded = Path.expand(path)

    unless path_allowed?(expanded) do
      {:error, "path not in allowed directories: #{expanded}"}
    else
      with :ok <- File.mkdir_p(Path.dirname(expanded)),
           :ok <- File.write(expanded, content) do
        {:ok, "Written #{byte_size(content)} bytes to #{expanded}"}
      else
        {:error, reason} -> {:error, "Write error: #{inspect(reason)}"}
      end
    end
  end

  def execute("edit_file", %{"old_string" => ""}) do
    {:error, "old_string cannot be empty"}
  end

  def execute("edit_file", %{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded = Path.expand(path)

    unless path_allowed?(expanded) do
      {:error, "path not in allowed directories: #{expanded}"}
    else
      case File.read(expanded) do
        {:ok, content} ->
          if String.contains?(content, old) do
            # Only replace first occurrence — matching Claude Code's behavior
            new_content = String.replace(content, old, new, global: false)

            case File.write(expanded, new_content) do
              :ok -> {:ok, "Edit applied to #{expanded}"}
              {:error, reason} -> {:error, "Write error: #{inspect(reason)}"}
            end
          else
            {:error, "old_string not found in file — no edit applied"}
          end

        {:error, :enoent} ->
          {:error, "File not found: #{expanded}"}

        {:error, reason} ->
          {:error, "Read error: #{inspect(reason)}"}
      end
    end
  end

  def execute("exec", %{"command" => cmd} = input) do
    # P0-1: Check for shell injection BEFORE allowlist check.
    # The allowlist checks only the first token (stem), so "git; rm -rf /" splits to "git"
    # and would pass. We reject the entire command if it contains shell metacharacters.
    if contains_shell_injection?(cmd) do
      Logger.warning("[Kyber.ToolExecutor] exec blocked (shell injection): #{String.slice(cmd, 0, 200)}")
      {:error, "Command contains disallowed shell operators"}
    else
      # Enforce a strict command allowlist — only safe, read-only tools.
      # The first token of the command (before any spaces, pipes, or flags)
      # must be one of the approved stems. This blocks arbitrary shell injection
      # while still allowing useful inspection commands.
      cmd_stem = cmd |> String.trim() |> String.split(~r/[\s|;&]/, parts: 2) |> List.first("")

    if cmd_stem not in @allowed_exec_commands do
      Logger.warning("[Kyber.ToolExecutor] exec blocked (not in allowlist): #{String.slice(cmd, 0, 200)}")
      {:error, "exec is restricted to: #{Enum.join(@allowed_exec_commands, ", ")}. Got: '#{cmd_stem}'"}
    else
      workdir = Map.get(input, "workdir", System.get_env("HOME", "/tmp"))
      timeout_ms = Map.get(input, "timeout_ms", 30_000)
      expanded_dir = Path.expand(workdir)

      Logger.info("[Kyber.ToolExecutor] exec: #{String.slice(cmd, 0, 500)}")

      # Use Port.open with OS process group tracking to prevent orphaned
      # processes on timeout. We start `sh` in its own process group via
      # `setsid` (or plain sh on macOS where setsid may not exist), capture
      # the OS PID, and kill the entire process group on timeout.
      exec_with_port(cmd, expanded_dir, timeout_ms)
    end
    end
  rescue
    e -> {:error, "exec failed: #{inspect(e)}"}
  end

  def execute("list_dir", %{"path" => path}) do
    expanded = Path.expand(path)

    unless read_path_allowed?(expanded) do
      {:error, "path not in allowed read directories: #{expanded}"}
    else
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

        {:error, :enoent} ->
          {:error, "Directory not found: #{expanded}"}

        {:error, reason} ->
          {:error, "List error: #{inspect(reason)}"}
      end
    end
  end

  # ── memory_read ──────────────────────────────────────────────────────────

  def execute("memory_read", %{"path" => path} = input) do
    tier_str = Map.get(input, "tier", "l2")

    tier =
      case tier_str do
        "l0" -> :l0
        "l1" -> :l1
        _ -> :l2
      end

    case Kyber.Knowledge.get_tiered(Kyber.Knowledge, path, tier) do
      {:ok, content} ->
        formatted = format_tiered_content(content, tier)
        {:ok, formatted}

      {:error, :not_found} ->
        {:error, "Note not found in vault: #{path}"}
    end
  rescue
    e -> {:error, "memory_read failed: #{inspect(e)}"}
  end

  # ── memory_write ─────────────────────────────────────────────────────────

  def execute("memory_write", %{"path" => path, "content" => content}) do
    # Reject paths with ".." components or absolute paths to prevent traversal
    if String.contains?(path, "..") or String.starts_with?(path, "/") do
      {:error, "invalid vault path: must be relative with no '..' components"}
    else
      normalized = path
      abs_path = Path.join(vault_path(), normalized)

      with :ok <- File.mkdir_p(Path.dirname(abs_path)),
           :ok <- File.write(abs_path, content) do
        # Trigger async vault reload by touching the file
        {:ok, "Written #{byte_size(content)} bytes to vault/#{normalized}"}
      else
        {:error, reason} -> {:error, "memory_write failed: #{inspect(reason)}"}
      end
    end
  end

  # ── memory_list ──────────────────────────────────────────────────────────

  def execute("memory_list", input) do
    subdir = Map.get(input, "subdir")

    # Reject ".." in subdir to prevent path traversal
    if subdir && String.contains?(subdir, "..") do
      {:error, "invalid vault path: must be relative with no '..' components"}
    else
      search_root =
        if subdir && subdir != "" do
          Path.join(vault_path(), String.trim_leading(subdir, "/"))
        else
          vault_path()
        end

      if File.dir?(search_root) do
        paths =
          Path.wildcard(Path.join([search_root, "**", "*.md"]))
          |> Enum.map(&Path.relative_to(&1, vault_path()))
          |> Enum.sort()
          |> Enum.join("\n")

        count = length(String.split(paths, "\n", trim: true))
        {:ok, "(#{count} notes)\n#{paths}"}
      else
        {:error, "Vault directory not found: #{search_root}"}
      end
    end
  end

  # ── memory pool management ────────────────────────────────────────────────

  def execute("memory_pin", %{"query" => query}) do
    try do
      case find_memory_by_query(query) do
        {:ok, mem} ->
          case Kyber.Memory.Consolidator.pin_memory(mem.id) do
            :ok ->
              display = memory_display_name(mem)
              {:ok, "📌 Pinned: #{display}"}

            {:error, :not_found} ->
              {:error, "Memory vanished during pin"}
          end

        {:error, :no_match} ->
          {:error, "No memory matching '#{query}'. This searches your memory pool by tags and vault note title."}

        {:error, :ambiguous, matches} ->
          names = Enum.map_join(matches, "\n- ", &memory_display_name/1)
          {:error, "Multiple matches — be more specific:\n- #{names}"}
      end
    catch
      :exit, _ -> {:error, "Memory.Consolidator not running"}
    end
  end

  def execute("memory_unpin", %{"query" => query}) do
    try do
      case find_memory_by_query(query) do
        {:ok, mem} ->
          case Kyber.Memory.Consolidator.unpin_memory(mem.id) do
            :ok ->
              display = memory_display_name(mem)
              {:ok, "Unpinned: #{display}"}

            {:error, :not_found} ->
              {:error, "Memory vanished during unpin"}
          end

        {:error, :no_match} ->
          {:error, "No memory matching '#{query}'."}

        {:error, :ambiguous, matches} ->
          names = Enum.map_join(matches, "\n- ", &memory_display_name/1)
          {:error, "Multiple matches — be more specific:\n- #{names}"}
      end
    catch
      :exit, _ -> {:error, "Memory.Consolidator not running"}
    end
  end

  # ── web_fetch ─────────────────────────────────────────────────────────────

  def execute("web_fetch", %{"url" => url} = input) do
    max_chars = Map.get(input, "max_chars")
    opts = if max_chars, do: [max_chars: max_chars], else: []

    case Kyber.Tools.WebFetch.fetch(url, opts) do
      {:ok, %{title: title, content: content, url: fetched_url, word_count: word_count}} ->
        title_line = if title, do: "Title: #{title}\n", else: ""
        {:ok, "#{title_line}URL: #{fetched_url}\nWords: #{word_count}\n\n#{content}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Phase 6: BEAM Introspection ───────────────────────────────────────────

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
    {:ok, Kyber.Introspection.ets_tables() |> format_list()}
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
      {:ok,
       "#{length(results)} processes with queues >= #{threshold}:\n#{format_list(results)}"}
    end
  end

  def execute("beam_gc", %{"target" => "all"}) do
    {:ok, Kyber.Introspection.gc_process(:all) |> format_map()}
  end

  def execute("beam_gc", %{"target" => name}) do
    atom = String.to_existing_atom(name)

    case Kyber.Introspection.gc_process(atom) do
      {:error, msg} -> {:error, msg}
      result -> {:ok, format_map(result)}
    end
  rescue
    ArgumentError -> {:error, "Unknown process: #{name}"}
  end

  def execute("beam_reload_module", %{"module" => mod}) do
    # Try with Elixir. prefix first (for Elixir modules), fall back to bare atom
    atom =
      try do
        String.to_existing_atom("Elixir." <> mod)
      rescue
        ArgumentError ->
          try do
            String.to_existing_atom(mod)
          rescue
            ArgumentError -> nil
          end
      end

    if atom do
      case Kyber.Introspection.reload_module(atom) do
        {:ok, msg} -> {:ok, msg}
        {:error, msg} -> {:error, msg}
      end
    else
      {:error, "Unknown module: #{mod}"}
    end
  end

  def execute("beam_io_stats", _input) do
    {:ok, Kyber.Introspection.io_stats() |> format_map()}
  end

  def execute("beam_ports", _input) do
    {:ok, Kyber.Introspection.port_info() |> format_map()}
  end

  # ── weather ──────────────────────────────────────────────────────────────

  def execute("weather", %{"location" => location}) do
    encoded = URI.encode(location)
    url = "https://wttr.in/#{encoded}?format=j1"

    Logger.info("[Kyber.ToolExecutor] weather: #{location}")

    case Req.get(url,
           connect_options: [timeout: 5_000],
           receive_timeout: 10_000
         ) do
      {:ok, %{status: 200, body: body}} ->
        parse_weather(body, location)

      {:ok, %{status: 404}} ->
        {:error, "Location not found: #{location}"}

      {:ok, %{status: status}} ->
        {:error, "Weather API returned HTTP #{status}"}

      {:error, reason} ->
        {:error, "Weather API unavailable: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "weather failed: #{inspect(e)}"}
  end

  # ── camera_snap ──────────────────────────────────────────────────────────

  def execute("camera_snap", input) do
    timestamp = System.system_time(:second)
    raw_path = Map.get(input, "output_path", "/tmp/stilgar_snap_#{timestamp}.jpg")
    output_path = Path.expand(raw_path)

    req_path = Kyber.Config.get(:snap_request_path, "/tmp/snap_request")
    res_path = Kyber.Config.get(:snap_result_path, "/tmp/snap_result")

    Logger.info("[Kyber.ToolExecutor] camera_snap: #{output_path}")

    # Remove any stale result file from a previous (possibly failed) snap
    File.rm(res_path)

    case File.write(req_path, output_path) do
      :ok ->
        # Poll for up to 5 seconds (10 attempts × 500ms)
        poll_snap_result(0, 10, req_path, res_path)

      {:error, reason} ->
        {:error, "Failed to write snap request: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "camera_snap failed: #{inspect(e)}"}
  end

  # ── Phase 9: Discord File Posting ──────────────────────────────────────────

  def execute("send_file", %{"file_path" => file_path} = input) do
    expanded = Path.expand(file_path)

    unless read_path_allowed?(expanded) do
      {:error, "path not in allowed directories: #{expanded}"}
    else
      unless File.exists?(expanded) do
        {:error, "File not found: #{expanded}"}
      else
        caption = Map.get(input, "caption", "")
        channel_id = Map.get(input, "channel_id")

        # Get the Discord token from the plugin's config
        token = Kyber.Config.get(:discord_token) ||
                System.get_env("DISCORD_BOT_TOKEN")

        if is_nil(token) do
          {:error, "Discord token not available"}
        else
          # If no channel_id provided, try to get it from the current context
          target_channel = channel_id || get_last_channel_id()

          if is_nil(target_channel) do
            {:error, "No channel_id provided and no recent channel context available"}
          else
            case Kyber.Plugin.Discord.send_file(token, target_channel, expanded, content: caption) do
              :ok ->
                {:ok, "File sent to channel #{target_channel}: #{Path.basename(expanded)}"}
              {:error, reason} ->
                {:error, "Failed to send file: #{inspect(reason)}"}
            end
          end
        end
      end
    end
  end

  # ── Phase 10: Vision ──────────────────────────────────────────────────────

  def execute("view_image", %{"path" => path}) do
    expanded = Path.expand(path)

    unless read_path_allowed?(expanded) do
      {:error, "path not in allowed directories: #{expanded}"}
    else
      unless File.exists?(expanded) do
        {:error, "File not found: #{expanded}"}
      else
        case File.read(expanded) do
          {:ok, data} ->
            # Detect media type from extension
            media_type =
              case Path.extname(expanded) |> String.downcase() do
                ".jpg" -> "image/jpeg"
                ".jpeg" -> "image/jpeg"
                ".png" -> "image/png"
                ".gif" -> "image/gif"
                ".webp" -> "image/webp"
                _ -> "image/jpeg"
              end

            base64_data = Base.encode64(data)

            # Return a special tuple that the LLM plugin recognizes as an image
            {:ok_image, %{
              "media_type" => media_type,
              "base64" => base64_data,
              "path" => expanded,
              "size_bytes" => byte_size(data)
            }}

          {:error, reason} ->
            {:error, "Failed to read image: #{inspect(reason)}"}
        end
      end
    end
  end

  # ── cleanup_tmp ──────────────────────────────────────────────────────────

  def execute("cleanup_tmp", input) do
    pattern = Map.get(input, "pattern", "stilgar_*")
    max_age_seconds = Map.get(input, "max_age_seconds", 3600)
    now = System.system_time(:second)
    prefix = String.replace_trailing(pattern, "*", "")

    tmp_dirs = ["/tmp", System.tmp_dir!()] |> Enum.uniq() |> Enum.filter(&File.dir?/1)

    {deleted, skipped, errors} =
      Enum.reduce(tmp_dirs, {[], [], []}, fn dir, acc ->
        case File.ls(dir) do
          {:ok, files} ->
            files
            |> Enum.filter(&String.starts_with?(&1, prefix))
            |> Enum.reduce(acc, fn f, {d, s, e} ->
              path = Path.join(dir, f)
              case File.stat(path, time: :posix) do
                {:ok, %{mtime: mtime}} when (now - mtime) > max_age_seconds ->
                  case File.rm(path) do
                    :ok -> {[path | d], s, e}
                    {:error, reason} -> {d, s, ["#{path}: #{reason}" | e]}
                  end
                {:ok, _} -> {d, [path | s], e}
                _ -> {d, s, ["#{path}: stat failed" | e]}
              end
            end)
          _ -> acc
        end
      end)

    {:ok, "Cleaned #{length(deleted)} file(s), skipped #{length(skipped)} (too recent), #{length(errors)} error(s)." <>
      if(deleted != [], do: "\nDeleted: #{Enum.join(deleted, ", ")}", else: "")}
  end

  # ── Phase 11: Web Search ─────────────────────────────────────────────────

  def execute("web_search", %{"query" => query} = input) do
    max_results =
      input
      |> Map.get("max_results", 5)
      |> min(20)
      |> max(1)

    Logger.info("[Kyber.ToolExecutor] web_search: #{query} (max_results: #{max_results})")

    case Kyber.Tools.WebSearch.search(query, max_results: max_results) do
      {:ok, results} ->
        formatted = format_search_results(query, results)
        {:ok, formatted}

      {:error, reason} ->
        {:error, "Web search failed: #{reason}"}
    end
  rescue
    e -> {:error, "web_search error: #{inspect(e)}"}
  end

  # ── Phase 12: Sub-agent Orchestration ──────────────────────────────────────

  def execute("spawn_task", %{"task_name" => task_name} = input) do
    task_params = Map.get(input, "task_params", %{})
    timeout_ms = Map.get(input, "timeout_ms", 30_000)

    registry = Process.whereis(Kyber.TaskRegistry)
    store = Process.whereis(Kyber.Delta.Store)
    task_sup = Process.whereis(Kyber.Effect.TaskSupervisor)

    cond do
      is_nil(registry) ->
        {:error, "TaskRegistry not running"}

      is_nil(store) ->
        {:error, "Delta.Store not running"}

      is_nil(task_sup) ->
        {:error, "TaskSupervisor not running"}

      true ->
        effect = %{
          type: :spawn_task,
          payload: %{
            "task_name" => task_name,
            "task_params" => task_params,
            "timeout_ms" => timeout_ms
          }
        }

        # Subscribe to delta store to capture the result
        caller = self()
        ref = make_ref()

        Kyber.Delta.Store.subscribe(store, fn delta ->
          kind = Map.get(delta, :kind)
          payload = Map.get(delta, :payload, %{})
          task_id_in_delta = Map.get(payload, "task_id")

          if kind in ["task.result", "task.error"] do
            send(caller, {:task_delta, ref, kind, task_id_in_delta, payload})
          end
        end)

        case Kyber.TaskSpawner.spawn_task(effect, registry, store, task_sup) do
          {:ok, task_id} ->
            # Wait for the result delta
            wait_for_task_result(ref, task_id, task_name, timeout_ms + 5_000)

          {:error, :unknown_task} ->
            {:error, "Unknown task: #{task_name}. Use list_tasks to see available tasks."}

          {:error, reason} ->
            {:error, "Failed to spawn task: #{inspect(reason)}"}
        end
    end
  rescue
    e -> {:error, "spawn_task failed: #{inspect(e)}"}
  end

  def execute("list_tasks", _input) do
    registry = Process.whereis(Kyber.TaskRegistry)

    if is_nil(registry) do
      {:error, "TaskRegistry not running"}
    else
      tasks = Kyber.TaskRegistry.list(registry)

      if tasks == [] do
        {:ok, "No tasks registered."}
      else
        {:ok, "Available tasks:\n" <> Enum.map_join(tasks, "\n", &("• #{&1}"))}
      end
    end
  rescue
    e -> {:error, "list_tasks failed: #{inspect(e)}"}
  end

  # ── Phase 12: Research Pipeline ────────────────────────────────────────────

  def execute("research", %{"query" => query} = input) do
    max_results = Map.get(input, "max_results", 3) |> min(5) |> max(1)
    max_chars_per_page = Map.get(input, "max_chars_per_page", 5_000)

    Logger.info("[Kyber.ToolExecutor] research: #{query} (top #{max_results} results)")

    # Step 1: Search
    search_result =
      case execute("web_search", %{"query" => query, "max_results" => max_results}) do
        {:ok, _} = ok -> ok
        {:error, reason} -> {:error, "Search step failed: #{reason}"}
      end

    case search_result do
      {:error, reason} ->
        {:error, reason}

      {:ok, search_text} ->
        # Step 2: Extract URLs from search results
        urls =
          search_text
          |> String.split("\n")
          |> Enum.filter(&String.contains?(&1, "URL: "))
          |> Enum.map(fn line ->
            line |> String.trim() |> String.replace_prefix("URL: ", "")
          end)
          |> Enum.filter(&String.starts_with?(&1, "http"))
          |> Enum.take(max_results)

        # Step 3: Fetch each URL
        fetched =
          urls
          |> Enum.with_index(1)
          |> Enum.map(fn {url, i} ->
            case Kyber.Tools.WebFetch.fetch(url, max_chars: max_chars_per_page) do
              {:ok, %{title: title, content: content, word_count: wc}} ->
                title_str = title || "Untitled"
                "── Source #{i}: #{title_str} ──\nURL: #{url}\nWords: #{wc}\n\n#{content}"

              {:error, reason} ->
                "── Source #{i}: FETCH FAILED ──\nURL: #{url}\nError: #{reason}"
            end
          end)

        combined =
          "Research results for: #{query}\n" <>
            "Searched and fetched #{length(urls)} source(s).\n\n" <>
            Enum.join(fetched, "\n\n")

        # Truncate combined output to 50KB
        if byte_size(combined) > 50_000 do
          {:ok, String.slice(combined, 0, 50_000) <> "\n\n[research output truncated to 50KB]"}
        else
          {:ok, combined}
        end
    end
  rescue
    e -> {:error, "research failed: #{inspect(e)}"}
  end

  # ── Catch-all ─────────────────────────────────────────────────────────────

  def execute(name, _input) do
    {:error, "Unknown tool: #{name}"}
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  # Wait for a task result delta matching the given task_id.
  defp wait_for_task_result(ref, task_id, task_name, timeout_ms) do
    receive do
      {:task_delta, ^ref, "task.result", ^task_id, data} ->
        result = Map.get(data, "result", "")
        {:ok, "Task '#{task_name}' completed.\nResult: #{inspect(result)}"}

      {:task_delta, ^ref, "task.error", ^task_id, data} ->
        reason = Map.get(data, "reason", "unknown")
        {:error, "Task '#{task_name}' failed: #{reason}"}

      # Handle deltas for other tasks — keep waiting
      {:task_delta, ^ref, _kind, _other_id, _data} ->
        wait_for_task_result(ref, task_id, task_name, timeout_ms)
    after
      timeout_ms ->
        {:error, "Timed out waiting for task '#{task_name}' result"}
    end
  end

  # Execute a command via Port with OS process group cleanup on timeout.
  # Starts `sh -c '<cmd>'` and tracks its OS PID. On timeout, sends SIGKILL
  # to the entire process group (-pid) to prevent orphaned child processes.
  defp exec_with_port(cmd, workdir, timeout_ms) do
    port =
      Port.open(
        {:spawn_executable, "/bin/sh"},
        [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          args: ["-c", cmd],
          cd: workdir
        ]
      )

    # Extract the OS PID of the spawned sh process
    {:os_pid, os_pid} = Port.info(port, :os_pid)

    # Use a wall-clock deadline so continuous output doesn't reset the timer
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    collect_port_output(port, os_pid, deadline, timeout_ms, _acc = "")
  end

  # Collect output from the port, enforcing a wall-clock deadline.
  # On timeout, kills the OS process group and closes the port.
  defp collect_port_output(port, os_pid, deadline, timeout_ms, acc) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      port_timeout_cleanup(port, os_pid, timeout_ms)
    else
      receive do
        {^port, {:data, data}} ->
          collect_port_output(port, os_pid, deadline, timeout_ms, acc <> data)

        {^port, {:exit_status, 0}} ->
          {:ok, truncate_output(acc)}

        {^port, {:exit_status, code}} ->
          {:ok, "[exit #{code}]\n#{truncate_output(acc)}"}
      after
        remaining ->
          port_timeout_cleanup(port, os_pid, timeout_ms)
      end
    end
  end

  defp port_timeout_cleanup(port, os_pid, timeout_ms) do
    # Kill the entire process group to prevent orphaned children.
    kill_os_process_group(os_pid)

    # Close the port (sends SIGTERM to any remaining process)
    catch_port_close(port)

    # Drain any remaining messages from the port
    drain_port_messages(port)

    {:error, "command timed out after #{timeout_ms}ms"}
  end

  # Drain any queued port messages to avoid polluting the caller's mailbox
  defp drain_port_messages(port) do
    receive do
      {^port, _} -> drain_port_messages(port)
    after
      0 -> :ok
    end
  end

  # Kill the OS process group. Uses negative PID to target the group.
  # Falls back to killing just the process if group kill fails.
  defp kill_os_process_group(os_pid) do
    # Try killing the process group first (negative PID)
    case System.cmd("kill", ["-9", "-#{os_pid}"], stderr_to_stdout: true) do
      {_, 0} ->
        :ok

      _ ->
        # Fallback: kill just the process
        System.cmd("kill", ["-9", "#{os_pid}"], stderr_to_stdout: true)
        :ok
    end
  rescue
    _ -> :ok
  end

  defp catch_port_close(port) do
    try do
      Port.close(port)
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    end
  end

  defp contains_shell_injection?(cmd) do
    # Reject commands containing shell chaining operators that could bypass allowlist.
    # This prevents "git; rm -rf /" (which would split to stem="git") from executing both parts.
    #
    # Blocked characters/sequences:
    #   ; | ` $ ( )  — chaining, subshell, command substitution
    #   > <          — file redirection (could overwrite arbitrary files)
    #   { }          — brace expansion
    #   \n \r        — newline injection (shell treats as command separator)
    #   && || $( `)  — compound operators (also caught by character-level check)
    #
    # NOTE: `2>&1` stderr redirects are NOT needed in commands — Port.open
    # already uses :stderr_to_stdout. Blocking `>` and `<` is safe.
    String.match?(cmd, ~r/[;|`$(){}<>\n\r]/) or
      String.contains?(cmd, ["&&", "||", "$(", "`"])
  end

  # Evaluate allowed roots at runtime so Path.expand uses the actual $HOME.
  # Using module attributes would bake in the build-time $HOME (wrong in CI).
  defp allowed_write_roots do
    [
      Path.expand("~/.kyber"),
      Path.expand("~/kyber-beam"),
      System.tmp_dir!(),
      "/tmp",
      "/private/tmp"
    ]
  end

  defp allowed_read_roots do
    [
      Path.expand("~/.kyber"),
      Path.expand("~/kyber-beam"),
      System.tmp_dir!(),
      "/tmp",
      "/private/tmp"
    ]
  end

  defp vault_path do
    Kyber.Config.get(:vault_path, Path.expand("~/.kyber/vault"))
  end

  # Returns true if the expanded path is under one of the allowed write roots.
  defp path_allowed?(expanded) do
    Enum.any?(allowed_write_roots(), &String.starts_with?(expanded, &1))
  end

  # Returns true if the expanded path is under one of the allowed read roots.
  defp read_path_allowed?(expanded) do
    Enum.any?(allowed_read_roots(), &String.starts_with?(expanded, &1))
  end

  # NOTE: SSRF protection for web_fetch moved to Kyber.Tools.WebFetch module.

  # Truncate command output to 100KB to prevent OOM and API rejections.
  @max_output_bytes 100_000

  defp truncate_output(output) do
    if byte_size(output) > @max_output_bytes do
      String.slice(output, 0, @max_output_bytes) <> "\n[output truncated to 100KB]"
    else
      output
    end
  end

  # Format tiered knowledge content as readable text.
  defp format_tiered_content(%{path: path, frontmatter: fm, body: body}, :l2) do
    fm_text =
      if map_size(fm) > 0 do
        pairs = Enum.map_join(fm, "\n", fn {k, v} -> "  #{k}: #{inspect(v)}" end)
        "Frontmatter:\n#{pairs}\n\n"
      else
        ""
      end

    "# #{path}\n#{fm_text}#{body}"
  end

  defp format_tiered_content(%{frontmatter: fm, first_paragraph: para}, :l1) do
    fm_text =
      if map_size(fm) > 0 do
        pairs = Enum.map_join(fm, "\n", fn {k, v} -> "  #{k}: #{inspect(v)}" end)
        "Frontmatter:\n#{pairs}\n\n"
      else
        ""
      end

    "#{fm_text}#{para}"
  end

  defp format_tiered_content(%{title: title, type: type, tags: tags}, :l0) do
    "Title: #{title}\nType: #{type}\nTags: #{Enum.join(tags, ", ")}"
  end

  defp format_tiered_content(other, _tier) do
    inspect(other)
  end

  # Format a map as readable key: value lines for LLM tool results.
  defp format_map(map) when is_map(map) do
    map
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join("\n")
  end

  defp format_map(other), do: inspect(other)

  # Format a list of maps as numbered entries.
  defp format_list(list) when is_list(list) do
    list
    |> Enum.with_index(1)
    |> Enum.map(fn
      {item, i} when is_map(item) -> "#{i}. #{format_map(item)}"
      {item, i} -> "#{i}. #{inspect(item)}"
    end)
    |> Enum.join("\n\n")
  end

  defp format_list(other), do: inspect(other)

  # NOTE: HTML text extraction moved to Kyber.Tools.WebFetch.extract_readable_text/1.

  # ── Search result formatting ───────────────────────────────────────────────

  defp format_search_results(query, []) do
    "No results found for: #{query}"
  end

  defp format_search_results(query, results) do
    header = "Search results for: #{query}\n\n"

    body =
      results
      |> Enum.with_index(1)
      |> Enum.map(fn {result, i} ->
        date_str = if result.date, do: " (#{result.date})", else: ""
        """
        #{i}. #{result.title}#{date_str}
           URL: #{result.url}
           #{result.snippet}
        """
      end)
      |> Enum.join("\n")

    header <> body
  end

  # ── Memory helpers (grouped below all execute/2 clauses) ─────────────────

  # Fetch a human-readable display name for a pool entry (vault_ref → L0 title).
  defp memory_display_name(mem) do
    vault_ref = Map.get(mem, :vault_ref, "")

    case knowledge_l0(vault_ref) do
      {:ok, %{title: title}} -> "#{title} (#{vault_ref})"
      _ -> vault_ref
    end
  end

  defp find_memory_by_query(query) do
    memories = Kyber.Memory.Consolidator.list_memories()
    query_lower = String.downcase(query)
    query_words = String.split(query_lower, ~r/\s+/, trim: true)

    scored =
      memories
      |> Enum.map(fn mem ->
        vault_ref = Map.get(mem, :vault_ref, "")
        mem_tags = Enum.map(Map.get(mem, :tags, []), &String.downcase/1)

        # Fetch L0 title from Knowledge for content-based matching
        title_lower =
          case knowledge_l0(vault_ref) do
            {:ok, %{title: title}} -> String.downcase(title)
            _ -> ""
          end

        ref_lower = String.downcase(vault_ref)

        # Score: tag matches worth 2, title/vault_ref word matches worth 1
        tag_score =
          Enum.count(query_words, fn w ->
            Enum.any?(mem_tags, &String.contains?(&1, w))
          end) * 2

        title_score =
          Enum.count(query_words, fn w ->
            String.contains?(title_lower, w) or String.contains?(ref_lower, w)
          end)

        total = tag_score + title_score
        {mem, total}
      end)
      |> Enum.filter(fn {_mem, score} -> score > 0 end)
      |> Enum.sort_by(fn {_mem, score} -> score end, :desc)

    case scored do
      [] ->
        {:error, :no_match}

      [{best, best_score} | rest] ->
        # If the top match is clearly better (1.5× score), use it
        if rest == [] or best_score > elem(hd(rest), 1) * 1.5 do
          {:ok, best}
        else
          top_matches = Enum.take([{best, best_score} | rest], 3) |> Enum.map(&elem(&1, 0))
          {:error, :ambiguous, top_matches}
        end
    end
  end

  # ── weather helpers ───────────────────────────────────────────────────────

  # Parse a decoded wttr.in j1 JSON response body into a formatted string.
  defp parse_weather(body, location) when is_map(body) do
    [current | _] = body["current_condition"]

    area_info = get_in(body, ["nearest_area", Access.at(0)])
    city = get_in(area_info, ["areaName", Access.at(0), "value"]) || location
    country = get_in(area_info, ["country", Access.at(0), "value"]) || ""

    temp_c = current["temp_C"]
    temp_f = current["temp_F"]
    feels_c = current["FeelsLikeC"]
    feels_f = current["FeelsLikeF"]
    humidity = current["humidity"]
    wind_kmph = current["windspeedKmph"]
    wind_dir = current["winddir16Point"]
    condition = get_in(current, ["weatherDesc", Access.at(0), "value"]) || "Unknown"

    location_str = if country != "", do: "#{city}, #{country}", else: city

    current_block = """
    🌤 Weather for #{location_str}

    Current Conditions:
    • Temperature: #{temp_c}°C / #{temp_f}°F
    • Feels like: #{feels_c}°C / #{feels_f}°F
    • Condition: #{condition}
    • Humidity: #{humidity}%
    • Wind: #{wind_kmph} km/h #{wind_dir}
    """

    forecast_block =
      body
      |> Map.get("weather", [])
      |> Enum.take(3)
      |> Enum.map(fn day ->
        date = day["date"]
        max_c = day["maxtempC"]
        min_c = day["mintempC"]
        max_f = day["maxtempF"]
        min_f = day["mintempF"]

        desc =
          day
          |> Map.get("hourly", [])
          |> Enum.at(4)
          |> then(&get_in(&1 || %{}, ["weatherDesc", Access.at(0), "value"]))
          |> Kernel.||("--")

        "  #{date}: #{min_c}–#{max_c}°C (#{min_f}–#{max_f}°F), #{desc}"
      end)
      |> Enum.join("\n")

    result =
      if forecast_block != "" do
        current_block <> "\n3-Day Forecast:\n#{forecast_block}"
      else
        current_block
      end

    {:ok, String.trim(result)}
  rescue
    e -> {:error, "Failed to parse weather data: #{inspect(e)}"}
  end

  defp parse_weather(_body, _location) do
    {:error, "Unexpected weather response format"}
  end

  # ── camera helpers ────────────────────────────────────────────────────────

  # Poll snap_result every 500ms for up to max_attempts × 500ms total.
  defp poll_snap_result(attempt, max_attempts, req_path, _res_path) when attempt >= max_attempts do
    File.rm(req_path)
    {:error, "Camera snap timed out after 5 seconds — snap daemon may not be running"}
  end

  defp poll_snap_result(attempt, max_attempts, req_path, res_path) do
    :timer.sleep(500)

    case File.read(res_path) do
      {:ok, result} ->
        # Always clean up both sentinel files
        File.rm(req_path)
        File.rm(res_path)

        result = String.trim(result)

        cond do
          String.starts_with?(result, "ok:") ->
            path = String.replace_prefix(result, "ok:", "")
            {:ok, "Photo saved: #{path}"}

          String.starts_with?(result, "error:") ->
            reason = String.replace_prefix(result, "error:", "")
            {:error, "Camera error: #{reason}"}

          true ->
            {:error, "Unexpected snap result: #{result}"}
        end

      {:error, :enoent} ->
        poll_snap_result(attempt + 1, max_attempts, req_path, res_path)

      {:error, reason} ->
        File.rm(req_path)
        {:error, "Error polling snap result: #{inspect(reason)}"}
    end
  end

  # Safely call Kyber.Knowledge.get_tiered at L0.
  defp knowledge_l0(vault_ref) do
    if Process.whereis(Kyber.Knowledge) do
      try do
        Kyber.Knowledge.get_tiered(Kyber.Knowledge, vault_ref, :l0)
      catch
        :exit, _ -> {:error, :not_running}
      end
    else
      {:error, :not_running}
    end
  end

  @doc """
  Store the current channel_id for tool context. Called by the LLM plugin
  before executing tools so send_file knows where to post.

  Uses process dictionary — safe because LLM handler runs tool execution
  in the same process (synchronous tool loop). No race conditions between
  concurrent conversations since each runs in its own process/task.
  """
  def set_channel_context(channel_id) do
    Process.put(:kyber_tool_channel_id, channel_id)
  end

  defp get_last_channel_id do
    Process.get(:kyber_tool_channel_id)
  end
end
