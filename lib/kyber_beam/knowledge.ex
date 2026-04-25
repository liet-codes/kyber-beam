defmodule Kyber.Knowledge do
  @moduledoc """
  Knowledge graph for Kyber — Obsidian-compatible vault integration.

  Reads, writes, and queries markdown notes with YAML frontmatter. Watches
  a vault directory via polling every 5 seconds to detect external changes.

  ## Note types
  - `:identity`  — SOUL.md-style identity notes
  - `:memory`    — daily YYYY-MM-DD.md notes
  - `:people`    — contact/relationship notes
  - `:projects`  — project tracking
  - `:concepts`  — ideas, theories, frameworks
  - `:tools`     — tool configs and notes
  - `:decisions` — decision records

  ## Tiered context
  - L0: Abstract — title + type + tags only
  - L1: Overview — frontmatter + first paragraph
  - L2: Full     — complete note content

  ## Wikilinks
  - Parse `[[wikilinks]]` from note bodies
  - Build a link graph for backlink queries

  ## Async reload + mtime-based polling

  Vault reloads run in a background `Task` so the GenServer is never blocked
  on file I/O. Reads always return from in-memory state (stale is fine during
  a reload window). Only files whose mtime has changed since the last poll are
  re-read, making polls O(changed) rather than O(all).
  """

  use GenServer
  require Logger

  @poll_interval_ms 5_000
  @valid_note_types ~w(identity memory people projects concepts tools decisions)a

  # Pre-compiled regexes — avoid Regex.compile! on every function call
  @frontmatter_regex Regex.compile!("^---\\s*$", "m")
  @wikilink_regex ~r/\[\[([^\]]+)\]\]/
  @paragraph_split_regex ~r/\n\n+/

  @type note_type :: :identity | :memory | :people | :projects | :concepts | :tools | :decisions

  @type note :: %{
    path: String.t(),
    frontmatter: map(),
    body: String.t(),
    wikilinks: [String.t()]
  }

  @type tier :: :l0 | :l1 | :l2

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Get a note by relative path within the vault."
  @spec get_note(GenServer.server(), String.t()) :: {:ok, note()} | {:error, :not_found}
  def get_note(server \\ __MODULE__, path) do
    GenServer.call(server, {:get_note, path})
  end

  @doc "Write a note to the vault."
  @spec put_note(GenServer.server(), String.t(), map(), String.t()) :: :ok | {:error, term()}
  def put_note(server \\ __MODULE__, path, frontmatter, body) do
    GenServer.call(server, {:put_note, path, frontmatter, body})
  end

  @doc "Delete a note from the vault."
  @spec delete_note(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def delete_note(server \\ __MODULE__, path) do
    GenServer.call(server, {:delete_note, path})
  end

  @doc """
  Query notes with filters.

  Filters (keyword list):
  - `type: :memory` — filter by note type
  - `tags: ["elixir", "phoenix"]` — must have ALL listed tags
  - `since: ~D[2025-01-01]` — filter by date (uses `date` frontmatter field)
  - `until: ~D[2025-12-31]` — filter by date
  """
  @spec query_notes(GenServer.server(), keyword()) :: [note()]
  def query_notes(server \\ __MODULE__, filters \\ []) do
    GenServer.call(server, {:query_notes, filters})
  end

  @doc "List all notes of a given type."
  @spec list_notes(GenServer.server(), note_type()) :: [note()]
  def list_notes(server \\ __MODULE__, type) do
    GenServer.call(server, {:list_notes, type})
  end

  @doc "Get notes that link to the given path (backlinks)."
  @spec get_backlinks(GenServer.server(), String.t()) :: [note()]
  def get_backlinks(server \\ __MODULE__, path) do
    GenServer.call(server, {:get_backlinks, path})
  end

  @doc """
  Get a note at a given context tier.

  - `:l0` — `%{title: ..., type: ..., tags: [...]}`
  - `:l1` — `%{frontmatter: ..., first_paragraph: ...}`
  - `:l2` — full note map
  """
  @spec get_tiered(GenServer.server(), String.t(), tier()) :: {:ok, map()} | {:error, :not_found}
  def get_tiered(server \\ __MODULE__, path, tier) do
    GenServer.call(server, {:get_tiered, path, tier})
  end

  @doc "Return the vault path this server is watching."
  @spec vault_path(GenServer.server()) :: String.t()
  def vault_path(server \\ __MODULE__) do
    GenServer.call(server, :vault_path)
  end

  @doc "Return the agent name this server is configured for."
  @spec agent_name(GenServer.server()) :: String.t()
  def agent_name(server \\ __MODULE__) do
    GenServer.call(server, :agent_name)
  end

  @doc "Return :multi_agent or :legacy layout."
  @spec vault_layout(GenServer.server()) :: :multi_agent | :legacy
  def vault_layout(server \\ __MODULE__) do
    GenServer.call(server, :vault_layout)
  end

  @doc "Return the number of notes currently loaded."
  @spec note_count(GenServer.server()) :: non_neg_integer()
  def note_count(server \\ __MODULE__) do
    GenServer.call(server, :note_count)
  end

  @doc """
  Change the vault path and reload all notes. Used primarily in tests
  for test isolation. Returns {:ok, note_count} on success.
  """
  @spec set_vault_path(GenServer.server(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def set_vault_path(server \\ __MODULE__, new_path) do
    GenServer.call(server, {:set_vault_path, new_path})
  end

  @doc """
  Subscribe the calling process to vault change notifications.

  When vault polling detects changed or deleted files, the server sends
  `{:vault_changed, [path1, path2, ...]}` to all subscribed PIDs.
  Paths are relative to the vault root.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server \\ __MODULE__) do
    GenServer.call(server, {:subscribe, self()})
  end

  @doc "Unsubscribe the calling process from vault change notifications."
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server \\ __MODULE__) do
    GenServer.call(server, {:unsubscribe, self()})
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    vault_dir = Keyword.get(opts, :vault_path, default_vault_path())
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval_ms)
    agent_name = Keyword.get(opts, :agent_name) || default_agent_name()
    layout = detect_vault_layout(vault_dir)

    state = %{
      vault_path: vault_dir,
      poll_interval: poll_interval,
      agent_name: agent_name,
      vault_layout: layout,
      notes: %{},          # path → note map
      link_graph: %{},     # path → [linked paths]
      file_mtimes: %{},    # rel_path → mtime (for incremental reloads)
      reload_task_ref: nil, # monitor ref of in-progress async reload (nil = idle)
      subscribers: []      # PIDs to notify on vault changes
    }

    # Defer vault load to handle_continue so init/1 returns immediately and
    # the supervisor is not blocked during potentially large vault traversals.
    # Polling is also scheduled from handle_continue after the load completes.
    {:ok, state, {:continue, :load_vault}}
  end

  @impl true
  def handle_continue(:load_vault, state) do
    state = load_vault_sync(state)

    if state.poll_interval > 0 do
      schedule_poll(state.poll_interval)
    end

    Logger.info("[Kyber.Knowledge] vault loaded from #{state.vault_path} (#{map_size(state.notes)} notes)")
    {:noreply, state}
  end

  @impl true
  def handle_call({:get_note, path}, _from, state) do
    normalized = normalize_path(path)

    note = resolve_note(normalized, state)

    case note do
      nil -> {:reply, {:error, :not_found}, state}
      note -> {:reply, {:ok, note}, state}
    end
  end

  def handle_call({:put_note, path, frontmatter, body}, _from, state) do
    normalized = normalize_path(path)
    storage_path = resolve_put_path(normalized, state)
    abs_path = Path.join(state.vault_path, storage_path)

    with :ok <- File.mkdir_p(Path.dirname(abs_path)),
         content = serialize_note(frontmatter, body),
         :ok <- File.write(abs_path, content)
    do
      note = build_note(storage_path, frontmatter, body)
      wikilinks = extract_wikilinks(body)
      note = Map.put(note, :wikilinks, wikilinks)

      new_notes = Map.put(state.notes, storage_path, note)
      new_graph = Map.put(state.link_graph, storage_path, wikilinks)

      # Update mtime so next poll skips this file
      new_mtimes = Map.put(state.file_mtimes, storage_path, get_mtime(abs_path))

      {:reply, :ok, %{state | notes: new_notes, link_graph: new_graph, file_mtimes: new_mtimes}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:delete_note, path}, _from, state) do
    normalized = normalize_path(path)

    case Map.get(state.notes, normalized) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _note ->
        abs_path = Path.join(state.vault_path, normalized)
        File.rm(abs_path)
        new_notes = Map.delete(state.notes, normalized)
        new_graph = Map.delete(state.link_graph, normalized)
        new_mtimes = Map.delete(state.file_mtimes, normalized)
        {:reply, :ok, %{state | notes: new_notes, link_graph: new_graph, file_mtimes: new_mtimes}}
    end
  end

  def handle_call({:query_notes, filters}, _from, state) do
    results =
      state.notes
      |> Map.values()
      |> apply_filters(filters)

    {:reply, results, state}
  end

  def handle_call({:list_notes, type}, _from, state) do
    type_str = to_string(type)

    results =
      state.notes
      |> Map.values()
      |> Enum.filter(fn note ->
        Map.get(note.frontmatter, "type") == type_str
      end)

    {:reply, results, state}
  end

  def handle_call({:get_backlinks, path}, _from, state) do
    normalized = normalize_path(path)
    # The "name" of this note (without extension) for wikilink matching
    note_name = Path.basename(normalized, ".md")

    backlinks =
      state.link_graph
      |> Enum.filter(fn {_source, links} ->
        Enum.any?(links, fn link ->
          String.downcase(link) == String.downcase(note_name) or
          String.downcase(link) == String.downcase(normalized)
        end)
      end)
      |> Enum.map(fn {source_path, _} -> Map.get(state.notes, source_path) end)
      |> Enum.reject(&is_nil/1)

    {:reply, backlinks, state}
  end

  def handle_call({:get_tiered, path, tier}, _from, state) do
    normalized = normalize_path(path)

    case resolve_note(normalized, state) do
      nil ->
        {:reply, {:error, :not_found}, state}

      note ->
        result = tiered_context(note, tier)
        {:reply, {:ok, result}, state}
    end
  end

  def handle_call(:vault_path, _from, state) do
    {:reply, state.vault_path, state}
  end

  def handle_call(:agent_name, _from, state) do
    {:reply, state.agent_name, state}
  end

  def handle_call(:vault_layout, _from, state) do
    {:reply, state.vault_layout, state}
  end

  def handle_call(:note_count, _from, state) do
    {:reply, map_size(state.notes), state}
  end

  def handle_call({:set_vault_path, new_path}, _from, state) do
    # Ensure directory exists
    File.mkdir_p!(new_path)

    # Cancel any pending reload
    new_state = cancel_pending_reload(state)

    # Update path and layout
    layout = detect_vault_layout(new_path)

    new_state = %{
      new_state |
      vault_path: new_path,
      vault_layout: layout,
      notes: %{},
      link_graph: %{},
      file_mtimes: %{}
    }

    # Load notes from new path (sync, like init)
    final_state = load_vault_sync(new_state)

    Logger.info("[Kyber.Knowledge] vault path changed to #{new_path} (#{map_size(final_state.notes)} notes)")
    {:reply, {:ok, map_size(final_state.notes)}, final_state}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    subs =
      if pid in state.subscribers do
        state.subscribers
      else
        [pid | state.subscribers]
      end

    {:reply, :ok, %{state | subscribers: subs}}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, %{state | subscribers: List.delete(state.subscribers, pid)}}
  end

  # ── handle_info ─────────────────────────────────────────────────────────────

  @impl true
  def handle_info(:poll_vault, %{reload_task_ref: ref} = state) when not is_nil(ref) do
    # A reload is already in progress — skip this poll to avoid a race where
    # two Tasks read/write vault state concurrently. The next scheduled poll
    # will retry once the current task has finished and cleared the ref.
    Logger.debug("[Kyber.Knowledge] reload already in progress — skipping poll")
    schedule_poll(state.poll_interval)
    {:noreply, state}
  end

  def handle_info(:poll_vault, state) do
    # Kick off an async vault reload — do NOT block the GenServer on file I/O.
    # Stale data continues to be served from state while the task runs.
    # Use spawn_monitor (no link) so a crash clears reload_task_ref without
    # propagating to the GenServer.
    server = self()
    vault_dir = state.vault_path
    old_mtimes = state.file_mtimes
    layout = state.vault_layout
    agent_name = state.agent_name

    {_pid, ref} = spawn_monitor(fn ->
      if File.dir?(vault_dir) do
        result = read_changed_notes(vault_dir, old_mtimes, layout: layout, agent_name: agent_name)
        send(server, {:reload_complete, result})
      end
    end)

    schedule_poll(state.poll_interval)
    {:noreply, %{state | reload_task_ref: ref}}
  end

  def handle_info({:reload_complete, {changed_notes, changed_graph, new_mtimes, deleted_paths}}, state) do
    # Atomically merge changed notes and drop deleted ones
    new_notes =
      state.notes
      |> Map.merge(changed_notes)
      |> Map.drop(deleted_paths)

    new_graph =
      state.link_graph
      |> Map.merge(changed_graph)
      |> Map.drop(deleted_paths)

    if map_size(changed_notes) > 0 or length(deleted_paths) > 0 do
      Logger.debug("[Kyber.Knowledge] vault updated: #{map_size(changed_notes)} changed, #{length(deleted_paths)} deleted")
    end

    # Notify subscribers of changed/deleted paths; prune dead PIDs
    changed_paths = Map.keys(changed_notes) ++ deleted_paths

    live_subscribers =
      if changed_paths != [] and state.subscribers != [] do
        Enum.filter(state.subscribers, fn pid ->
          if Process.alive?(pid) do
            send(pid, {:vault_changed, changed_paths})
            true
          else
            false
          end
        end)
      else
        state.subscribers
      end

    {:noreply, %{state | notes: new_notes, link_graph: new_graph, file_mtimes: new_mtimes, subscribers: live_subscribers, reload_task_ref: nil}}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{reload_task_ref: ref} = state)
      when not is_nil(ref) do
    # Reload task crashed before sending {:reload_complete, ...}. Clear the
    # ref so the next poll can start a fresh reload.
    Logger.error("[Kyber.Knowledge] reload task crashed: #{inspect(reason)}")
    {:noreply, %{state | reload_task_ref: nil}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  # Cancel any pending reload task
  defp cancel_pending_reload(%{reload_task_ref: nil} = state), do: state

  defp cancel_pending_reload(%{reload_task_ref: ref} = state) do
    Process.demonitor(ref, [:flush])
    %{state | reload_task_ref: nil}
  end

  defp default_vault_path do
    Path.expand("~/.kyber/vault")
  end

  defp default_agent_name do
    try do
      Kyber.Config.get(:agent_name, "stilgar")
    rescue
      _ -> "stilgar"
    end
  end

  @doc false
  def detect_vault_layout(vault_dir) do
    cond do
      File.dir?(Path.join(vault_dir, "agents")) -> :multi_agent
      File.dir?(Path.join(vault_dir, "shared")) -> :multi_agent
      true -> :legacy
    end
  end

  # Resolve a note lookup path to the actual stored path.
  # In legacy layout, paths are used as-is.
  # In multi-agent layout:
  #   - "SOUL.md" → "agents/<agent>/SOUL.md" (agent-relative)
  #   - "memory/2026-03-20.md" → "agents/<agent>/memory/2026-03-20.md"
  #   - "concepts/foo.md" → "shared/concepts/foo.md"
  #   - "agents/liet/SOUL.md" → used as-is (explicit cross-agent)
  #   - "shared/concepts/foo.md" → used as-is (explicit shared)
  defp resolve_note(normalized, %{vault_layout: :legacy} = state) do
    Map.get(state.notes, normalized)
  end

  defp resolve_note(normalized, state) do
    # 1. Direct match (works for full paths like "shared/concepts/foo.md" or "agents/liet/SOUL.md")
    case Map.get(state.notes, normalized) do
      nil ->
        # 2. Try as agent-relative path: "SOUL.md" → "agents/<agent>/SOUL.md"
        agent_path = Path.join(["agents", state.agent_name, normalized])
        case Map.get(state.notes, agent_path) do
          nil ->
            # 3. Try as shared path: "concepts/foo.md" → "shared/concepts/foo.md"
            shared_path = Path.join("shared", normalized)
            Map.get(state.notes, shared_path)
          note -> note
        end
      note -> note
    end
  end

  # Resolve where to store a note on put.
  # In legacy layout, paths are used as-is.
  # In multi-agent layout, route based on content type:
  #   - Already prefixed with "shared/" or "agents/" → use as-is
  #   - Identity/memory-like paths → agents/<agent>/<path>
  #   - Shared types (concepts/, people/, projects/) → shared/<path>
  defp resolve_put_path(normalized, %{vault_layout: :legacy}), do: normalized

  defp resolve_put_path(normalized, state) do
    cond do
      # Already has explicit prefix
      String.starts_with?(normalized, "shared/") -> normalized
      String.starts_with?(normalized, "agents/") -> normalized

      # Shared note types
      String.starts_with?(normalized, "concepts/") -> Path.join("shared", normalized)
      String.starts_with?(normalized, "people/") -> Path.join("shared", normalized)
      String.starts_with?(normalized, "projects/") -> Path.join("shared", normalized)

      # Everything else goes under the agent dir
      true -> Path.join(["agents", state.agent_name, normalized])
    end
  end

  defp schedule_poll(0), do: :ok

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll_vault, interval)
  end

  # Synchronous full load — used only at startup
  defp load_vault_sync(%{vault_path: vault_dir} = state) do
    if File.dir?(vault_dir) do
      {notes, graph, mtimes} = read_all_notes(vault_dir, state)
      %{state | notes: notes, link_graph: graph, file_mtimes: mtimes}
    else
      state
    end
  end

  # Read ALL notes (used at startup); returns {notes, graph, mtimes}
  defp read_all_notes(vault_dir, %{vault_layout: :legacy}) do
    scan_md_files(vault_dir, vault_dir)
  end

  defp read_all_notes(vault_dir, %{vault_layout: :multi_agent, agent_name: agent_name}) do
    shared_dir = Path.join(vault_dir, "shared")
    agent_dir = Path.join([vault_dir, "agents", agent_name])

    # Scan shared/ and agents/<agent_name>/
    dirs = [shared_dir, agent_dir] |> Enum.filter(&File.dir?/1)

    Enum.reduce(dirs, {%{}, %{}, %{}}, fn dir, acc ->
      merge_scan(acc, scan_md_files(dir, vault_dir))
    end)
  end

  defp scan_md_files(dir, vault_dir) do
    md_files = Path.wildcard(Path.join([dir, "**", "*.md"]))

    Enum.reduce(md_files, {%{}, %{}, %{}}, fn abs_path, {notes, graph, mtimes} ->
      rel_path = Path.relative_to(abs_path, vault_dir)
      mtime = get_mtime(abs_path)

      case read_note_file(abs_path, rel_path) do
        {:ok, note} ->
          {
            Map.put(notes, rel_path, note),
            Map.put(graph, rel_path, note.wikilinks),
            Map.put(mtimes, rel_path, mtime)
          }

        {:error, _} ->
          {notes, graph, mtimes}
      end
    end)
  end

  defp merge_scan({n1, g1, m1}, {n2, g2, m2}) do
    {Map.merge(n1, n2), Map.merge(g1, g2), Map.merge(m1, m2)}
  end

  defp scan_dirs_for_md(vault_dir, :legacy, _agent_name) do
    Path.wildcard(Path.join([vault_dir, "**", "*.md"]))
  end

  defp scan_dirs_for_md(vault_dir, :multi_agent, agent_name) do
    shared_dir = Path.join(vault_dir, "shared")
    agent_dir = Path.join([vault_dir, "agents", agent_name])

    [shared_dir, agent_dir]
    |> Enum.filter(&File.dir?/1)
    |> Enum.flat_map(fn dir -> Path.wildcard(Path.join([dir, "**", "*.md"])) end)
  end

  # Incremental reload — only re-reads files whose mtime changed.
  # Returns {changed_notes, changed_graph, new_full_mtimes, deleted_paths}
  defp read_changed_notes(vault_dir, old_mtimes, opts) do
    layout = Keyword.get(opts, :layout, :legacy)
    agent_name = Keyword.get(opts, :agent_name, "stilgar")

    md_files = scan_dirs_for_md(vault_dir, layout, agent_name)

    # Build updated mtime map and collect changed files
    {new_mtimes, changed_files} =
      Enum.reduce(md_files, {%{}, []}, fn abs_path, {mtimes_acc, changed} ->
        rel_path = Path.relative_to(abs_path, vault_dir)
        mtime = get_mtime(abs_path)
        old_mtime = Map.get(old_mtimes, rel_path)

        changed =
          if mtime != old_mtime do
            [{abs_path, rel_path} | changed]
          else
            changed
          end

        {Map.put(mtimes_acc, rel_path, mtime), changed}
      end)

    # Detect deleted files (were tracked, no longer present)
    deleted_paths = Map.keys(old_mtimes) -- Map.keys(new_mtimes)

    # Re-read only changed files
    {changed_notes, changed_graph} =
      Enum.reduce(changed_files, {%{}, %{}}, fn {abs_path, rel_path}, {notes, graph} ->
        case read_note_file(abs_path, rel_path) do
          {:ok, note} ->
            {Map.put(notes, rel_path, note), Map.put(graph, rel_path, note.wikilinks)}

          {:error, _} ->
            {notes, graph}
        end
      end)

    {changed_notes, changed_graph, new_mtimes, deleted_paths}
  end

  defp get_mtime(abs_path) do
    case File.stat(abs_path) do
      {:ok, %{mtime: mtime}} -> mtime
      _ -> nil
    end
  end

  defp read_note_file(abs_path, rel_path) do
    case File.read(abs_path) do
      {:ok, content} ->
        {frontmatter, body} = parse_frontmatter(content)
        wikilinks = extract_wikilinks(body)
        note = build_note(rel_path, frontmatter, body)
        note = Map.put(note, :wikilinks, wikilinks)
        {:ok, note}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_note(path, frontmatter, body) do
    %{
      path: path,
      frontmatter: frontmatter,
      body: body,
      wikilinks: []
    }
  end

  @doc false
  def parse_frontmatter(content) do
    case String.split(content, @frontmatter_regex, parts: 3) do
      ["", yaml_str, rest] ->
        frontmatter = parse_yaml(yaml_str)
        {frontmatter, String.trim_leading(rest)}

      _ ->
        {%{}, content}
    end
  end

  defp parse_yaml(yaml_str) do
    case YamlElixir.read_from_string(yaml_str) do
      {:ok, map} when is_map(map) -> map
      _ -> %{}
    end
  end

  @doc false
  def serialize_note(frontmatter, body) do
    yaml = frontmatter_to_yaml(frontmatter)
    "---\n#{yaml}---\n\n#{body}"
  end

  defp frontmatter_to_yaml(map) when map == %{}, do: ""

  defp frontmatter_to_yaml(map) do
    map
    |> Enum.map_join("\n", fn {k, v} -> "#{k}: #{yaml_value(v)}" end)
    |> then(&(&1 <> "\n"))
  end

  defp yaml_value(v) when is_binary(v) do
    if String.contains?(v, ["\n", ":"]) do
      "\"#{String.replace(v, "\"", "\\\"")}\""
    else
      v
    end
  end

  defp yaml_value(v) when is_list(v), do: Jason.encode!(v)

  defp yaml_value(v) when is_map(v), do: Jason.encode!(v)

  defp yaml_value(v), do: to_string(v)

  @doc false
  def extract_wikilinks(body) do
    @wikilink_regex
    |> Regex.scan(body, capture: :all_but_first)
    |> Enum.map(fn [link] ->
      # Support display text: [[path|display]] — take only path part
      link |> String.split("|") |> hd() |> String.trim()
    end)
    |> Enum.uniq()
  end

  defp apply_filters(notes, filters) do
    Enum.reduce(filters, notes, fn
      {:type, type}, acc ->
        type_str = to_string(type)
        Enum.filter(acc, fn n -> Map.get(n.frontmatter, "type") == type_str end)

      {:tags, tags}, acc ->
        tag_list = List.wrap(tags) |> Enum.map(&to_string/1)
        Enum.filter(acc, fn n ->
          note_tags = Map.get(n.frontmatter, "tags", []) |> List.wrap()
          Enum.all?(tag_list, &(&1 in note_tags))
        end)

      {:since, since_date}, acc ->
        Enum.filter(acc, fn n ->
          case parse_note_date(n) do
            nil -> false
            d -> Date.compare(d, since_date) != :lt
          end
        end)

      {:until, until_date}, acc ->
        Enum.filter(acc, fn n ->
          case parse_note_date(n) do
            nil -> false
            d -> Date.compare(d, until_date) != :gt
          end
        end)

      _, acc ->
        acc
    end)
  end

  defp parse_note_date(note) do
    raw = Map.get(note.frontmatter, "date")

    cond do
      is_binary(raw) ->
        case Date.from_iso8601(raw) do
          {:ok, d} -> d
          _ -> nil
        end

      is_struct(raw, Date) ->
        raw

      true ->
        nil
    end
  end

  defp tiered_context(note, :l0) do
    %{
      title: Map.get(note.frontmatter, "title", Path.basename(note.path, ".md")),
      type: Map.get(note.frontmatter, "type"),
      tags: Map.get(note.frontmatter, "tags", [])
    }
  end

  defp tiered_context(note, :l1) do
    first_para =
      note.body
      |> String.split(@paragraph_split_regex, parts: 2)
      |> hd()
      |> String.trim()

    %{
      frontmatter: note.frontmatter,
      first_paragraph: first_para
    }
  end

  defp tiered_context(note, :l2) do
    note
  end

  defp normalize_path(path) do
    path
    |> String.trim_leading("/")
    |> then(fn p ->
      if String.ends_with?(p, ".md"), do: p, else: p <> ".md"
    end)
  end

  @doc false
  def valid_note_types, do: @valid_note_types
end
