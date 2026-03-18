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
  """

  use GenServer
  require Logger

  @poll_interval_ms 5_000
  @valid_note_types ~w(identity memory people projects concepts tools decisions)a

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

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    vault_dir = Keyword.get(opts, :vault_path, default_vault_path())
    poll_interval = Keyword.get(opts, :poll_interval, @poll_interval_ms)

    state = %{
      vault_path: vault_dir,
      poll_interval: poll_interval,
      notes: %{},        # path → note map
      link_graph: %{}    # path → [linked paths]
    }

    # Initial load
    state = load_vault(state)

    # Schedule polling
    if poll_interval > 0 do
      schedule_poll(poll_interval)
    end

    Logger.info("[Kyber.Knowledge] vault loaded from #{vault_dir} (#{map_size(state.notes)} notes)")
    {:ok, state}
  end

  @impl true
  def handle_call({:get_note, path}, _from, state) do
    case Map.get(state.notes, normalize_path(path)) do
      nil -> {:reply, {:error, :not_found}, state}
      note -> {:reply, {:ok, note}, state}
    end
  end

  def handle_call({:put_note, path, frontmatter, body}, _from, state) do
    normalized = normalize_path(path)
    abs_path = Path.join(state.vault_path, normalized)

    with :ok <- File.mkdir_p(Path.dirname(abs_path)),
         content = serialize_note(frontmatter, body),
         :ok <- File.write(abs_path, content) do
      note = build_note(normalized, frontmatter, body)
      wikilinks = extract_wikilinks(body)
      note = Map.put(note, :wikilinks, wikilinks)

      new_notes = Map.put(state.notes, normalized, note)
      new_graph = Map.put(state.link_graph, normalized, wikilinks)

      {:reply, :ok, %{state | notes: new_notes, link_graph: new_graph}}
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
        {:reply, :ok, %{state | notes: new_notes, link_graph: new_graph}}
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
    case Map.get(state.notes, normalize_path(path)) do
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

  @impl true
  def handle_info(:poll_vault, state) do
    new_state = load_vault(state)
    schedule_poll(state.poll_interval)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  defp default_vault_path do
    Path.expand("~/.kyber/vault")
  end

  defp schedule_poll(interval) do
    Process.send_after(self(), :poll_vault, interval)
  end

  defp load_vault(%{vault_path: vault_dir} = state) do
    if File.dir?(vault_dir) do
      {notes, graph} = read_all_notes(vault_dir)
      %{state | notes: notes, link_graph: graph}
    else
      state
    end
  end

  defp read_all_notes(vault_dir) do
    md_files = Path.wildcard(Path.join([vault_dir, "**", "*.md"]))

    Enum.reduce(md_files, {%{}, %{}}, fn abs_path, {notes, graph} ->
      rel_path = Path.relative_to(abs_path, vault_dir)

      case read_note_file(abs_path, rel_path) do
        {:ok, note} ->
          new_notes = Map.put(notes, rel_path, note)
          new_graph = Map.put(graph, rel_path, note.wikilinks)
          {new_notes, new_graph}

        {:error, _} ->
          {notes, graph}
      end
    end)
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
    case String.split(content, ~r/^---\s*$/m, parts: 3) do
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

  defp yaml_value(v) when is_list(v) do
    "[#{Enum.join(v, ", ")}]"
  end

  defp yaml_value(v), do: to_string(v)

  @doc false
  def extract_wikilinks(body) do
    ~r/\[\[([^\]]+)\]\]/
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
      |> String.split(~r/\n\n+/, parts: 2)
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
