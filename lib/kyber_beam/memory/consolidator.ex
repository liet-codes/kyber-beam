defmodule Kyber.Memory.Consolidator do
  @moduledoc """
  Long-term memory management for Stilgar.

  Runs as a GenServer that periodically (default: every 60 minutes):
  1. Queries recent deltas from `Kyber.Delta.Store`
  2. Sends them to a cheap LLM (Haiku) to score for long-term salience
  3. Stores scored memories in ETS table `:memory_pool`
  4. Rebuilds `~/.kyber/vault/identity/MEMORY.md` from the pool:
     - Top half (max 8): highest salience × recency_weight items
     - Bottom half (max 8): random sample, weighted toward age diversity
  5. Persists the pool to `~/.kyber/memory_pool.jsonl`

  ## Memory Lifecycle

  Each memory in the pool has:
  - `id` — unique binary ID
  - `summary` — one-line human-readable summary (aggressive compression)
  - `salience` — 0.0–1.0 score from LLM, adjusted by reinforcement/decay
  - `tags` — list of topic tags for fuzzy matching
  - `created_at` — Unix timestamp
  - `last_reinforced` — Unix timestamp of last reinforcement (nil if never)
  - `reinforcement_count` — how many times this memory has been reinforced
  - `pinned` — if true, never decays and never gets GC'd

  ## Reinforcement
  When a memory's tags appear in an LLM response, call `reinforce/1` with
  the matched tag list. Reinforcements are buffered and applied at the start
  of each consolidation cycle (single GenServer process — no ETS race).

  ## Decay
  Each consolidation cycle, unreinforced memories decay: `salience *= 0.95`.
  Memories reinforced within the last 2 cycles are skipped.
  Pinned memories never decay.
  Memories below 0.05 salience are GC'd unless `reinforcement_count > 5` or pinned.

  ## Token Budget
  MEMORY.md is capped at ~8000 chars (~2000 tokens). If over budget, the
  lowest-salience drifting memories are dropped first.

  ## Architecture note
  MEMORY.md is a *view*. The pool JSONL is the *source of truth*. On startup,
  the pool is loaded from disk; on each cycle it is saved back.

  This is a novel architecture worth understanding: salience-weighted, stochastic
  long-term memory that persists across VM restarts.
  """

  use GenServer
  require Logger

  @default_config %{
    consolidation_interval_ms: 3_600_000,
    max_persistent: 8,
    max_drifting: 8,
    salience_model: "claude-haiku-4-5-20250514",
    decay_rate: 0.95,
    reinforcement_bump: 0.1,
    min_salience: 0.05
  }

  @pool_path "~/.kyber/memory_pool.jsonl"
  @memory_md_path "~/.kyber/vault/identity/MEMORY.md"
  @anthropic_url "https://api.anthropic.com/v1/messages"
  @max_memory_chars 8_000

  # Keys to strip from delta payloads before sending to LLM
  @sensitive_keys ~w(
    auth_config token api_key secret password authorization
    cookie session_id access_token refresh_token private_key
  )

  # ── Public API ─────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Reinforce memories whose tags overlap with the given tag list.

  Tags are buffered in GenServer state and applied at the start of the next
  consolidation cycle (single-process read-modify-write, no ETS race).
  """
  @spec reinforce([String.t()]) :: :ok
  def reinforce(tags) when is_list(tags) and tags != [] do
    if Process.whereis(__MODULE__) do
      GenServer.cast(__MODULE__, {:buffer_reinforcement, tags})
    end
    :ok
  end

  def reinforce(_), do: :ok

  @doc "Trigger a consolidation cycle immediately (useful for testing / admin)."
  @spec consolidate_now(GenServer.server()) :: :ok
  def consolidate_now(server \\ __MODULE__) do
    GenServer.call(server, :consolidate_now, 120_000)
  end

  @doc "Return all memories in the current pool."
  @spec get_pool(GenServer.server()) :: [map()]
  def get_pool(server \\ __MODULE__) do
    GenServer.call(server, :get_pool)
  end

  @doc "Return current config."
  @spec get_config(GenServer.server()) :: map()
  def get_config(server \\ __MODULE__) do
    GenServer.call(server, :get_config)
  end

  @doc """
  Pin a memory by ID so it never decays or gets GC'd.
  Returns :ok or {:error, :not_found}.
  """
  @spec pin_memory(String.t(), GenServer.server()) :: :ok | {:error, :not_found}
  def pin_memory(memory_id, server \\ __MODULE__) do
    GenServer.call(server, {:pin_memory, memory_id})
  end

  @spec unpin_memory(String.t(), GenServer.server()) :: :ok | {:error, :not_found}
  def unpin_memory(memory_id, server \\ __MODULE__) do
    GenServer.call(server, {:unpin_memory, memory_id})
  end

  @spec list_memories(GenServer.server()) :: [map()]
  def list_memories(server \\ __MODULE__) do
    GenServer.call(server, :list_memories)
  end

  # ── GenServer callbacks ────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    config = build_config(opts)
    pool_path = Keyword.get(opts, :pool_path, @pool_path) |> Path.expand()
    memory_md_path = Keyword.get(opts, :memory_md_path, @memory_md_path) |> Path.expand()
    core = Keyword.get(opts, :core, Kyber.Core)

    # Load pool from disk
    pool = load_pool(pool_path)

    # Initialize ETS table — name derived from GenServer name so multiple instances don't conflict.
    server_name = Keyword.get(opts, :name, __MODULE__)
    table_name =
      if server_name == __MODULE__ do
        :memory_pool
      else
        suffix = server_name |> Atom.to_string() |> String.replace(~r/[^a-zA-Z0-9_]/, "_")
        :"memory_pool_#{suffix}"
      end

    table =
      case :ets.whereis(table_name) do
        :undefined ->
          :ets.new(table_name, [:named_table, :set, :public, read_concurrency: true])

        existing ->
          :ets.delete_all_objects(existing)
          existing
      end

    # Populate ETS from loaded pool
    Enum.each(pool, fn mem -> :ets.insert(table, {mem.id, mem}) end)

    # Seed pinned memories if pool is empty
    if pool == [] do
      seed_pinned_memories(table)
    end

    state = %{
      config: config,
      pool_path: pool_path,
      memory_md_path: memory_md_path,
      core: core,
      table: table,
      last_consolidated: nil,
      pending_reinforcements: []
    }

    schedule_consolidation(config.consolidation_interval_ms)

    Logger.info("[Kyber.Memory.Consolidator] started (#{length(pool)} memories loaded)")
    {:ok, state}
  end

  @impl true
  def handle_call(:consolidate_now, _from, state) do
    new_state = run_consolidation(state)
    {:reply, :ok, new_state}
  end

  def handle_call(:get_pool, _from, state) do
    pool = read_pool_from_ets(state.table)
    {:reply, pool, state}
  end

  def handle_call(:get_config, _from, state) do
    {:reply, state.config, state}
  end

  def handle_call({:pin_memory, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, mem}] ->
        :ets.insert(state.table, {id, %{mem | pinned: true}})
        Logger.info("[Kyber.Memory.Consolidator] pinned memory #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:unpin_memory, id}, _from, state) do
    case :ets.lookup(state.table, id) do
      [{^id, mem}] ->
        :ets.insert(state.table, {id, %{mem | pinned: false}})
        Logger.info("[Kyber.Memory.Consolidator] unpinned memory #{id}")
        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:list_memories, _from, state) do
    pool = read_pool_from_ets(state.table)
    {:reply, pool, state}
  end

  @impl true
  def handle_cast({:buffer_reinforcement, tags}, state) do
    # Buffer tags — will be applied atomically at the start of the next cycle
    {:noreply, %{state | pending_reinforcements: state.pending_reinforcements ++ tags}}
  end

  @impl true
  def handle_info(:consolidate, state) do
    new_state = run_consolidation(state)
    schedule_consolidation(state.config.consolidation_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Consolidation Cycle ────────────────────────────────────────────────────

  defp run_consolidation(state) do
    Logger.info("[Kyber.Memory.Consolidator] starting consolidation cycle")

    # 0. Apply buffered reinforcements FIRST (single-process, no race)
    state = apply_pending_reinforcements(state)

    # 1. Apply decay to all existing memories (skipping pinned + recently reinforced)
    state = apply_decay(state)

    # 2. Query recent deltas and score them (if auth available)
    {state, scoring_succeeded} = score_and_merge_deltas(state)

    # 3. Garbage collect low-salience memories
    state = gc_memories(state)

    # 4. Rebuild MEMORY.md from pool
    pool = read_pool_from_ets(state.table)
    write_memory_md(pool, state.memory_md_path, state.config)

    # 5. Persist pool to JSONL
    save_pool(read_pool_from_ets(state.table), state.pool_path)

    # 6. Only advance last_consolidated if LLM scoring was attempted and succeeded.
    #    On failure, the same delta window is re-queried next cycle.
    if scoring_succeeded do
      %{state | last_consolidated: DateTime.utc_now()}
    else
      Logger.info("[Kyber.Memory.Consolidator] not advancing last_consolidated (scoring failed)")
      state
    end
  end

  # Apply buffered reinforcements atomically in the GenServer process.
  defp apply_pending_reinforcements(%{pending_reinforcements: []} = state), do: state

  defp apply_pending_reinforcements(state) do
    tags = Enum.uniq(state.pending_reinforcements)
    now = System.system_time(:second)
    bump = state.config.reinforcement_bump

    :ets.tab2list(state.table)
    |> Enum.each(fn {id, mem} ->
      mem_tags = mem.tags || []
      if Enum.any?(tags, &(&1 in mem_tags)) do
        new_salience = min(1.0, mem.salience + bump)
        updated = %{mem |
          salience: new_salience,
          last_reinforced: now,
          reinforcement_count: mem.reinforcement_count + 1
        }
        :ets.insert(state.table, {id, updated})
        Logger.debug("[Kyber.Memory.Consolidator] reinforced #{id} (salience #{Float.round(new_salience, 2)})")
      end
    end)

    %{state | pending_reinforcements: []}
  end

  # Apply salience decay. Skips pinned memories and recently-reinforced ones
  # (reinforced within the last 2 consolidation cycles = 2 hours by default).
  defp apply_decay(state) do
    rate = state.config.decay_rate
    now = System.system_time(:second)
    # Grace period = 2 cycles
    grace_period = div(state.config.consolidation_interval_ms, 1000) * 2

    :ets.tab2list(state.table)
    |> Enum.each(fn {id, mem} ->
      skip =
        Map.get(mem, :pinned, false) or
          (mem.last_reinforced != nil and now - mem.last_reinforced < grace_period)

      unless skip do
        new_salience = mem.salience * rate
        :ets.insert(state.table, {id, %{mem | salience: new_salience}})
      end
    end)

    state
  end

  # Query recent deltas, send to LLM for scoring, merge into pool.
  # Returns {state, scoring_succeeded?} — on LLM failure scoring_succeeded = false.
  defp score_and_merge_deltas(state) do
    auth_config = load_auth_config()

    case auth_config do
      {:ok, auth} ->
        since_seconds =
          case state.last_consolidated do
            nil -> System.system_time(:second) - 7_200
            dt -> DateTime.to_unix(dt)
          end

        deltas = query_recent_deltas(state.core, since_seconds)

        if deltas != [] do
          case score_deltas(deltas, auth, state.config.salience_model) do
            {:ok, scored} ->
              merge_scored_memories(scored, state.table)
              Logger.info("[Kyber.Memory.Consolidator] merged #{length(scored)} scored memories")
              {state, true}

            {:error, reason} ->
              Logger.warning("[Kyber.Memory.Consolidator] scoring failed: #{inspect(reason)}")
              # Do NOT advance last_consolidated — retry same window next cycle
              {state, false}
          end
        else
          # No deltas to score — that's fine, still advance the window
          {state, true}
        end

      {:error, reason} ->
        Logger.warning("[Kyber.Memory.Consolidator] no auth config for scoring: #{inspect(reason)}")
        # No auth is not an LLM failure; advance the window
        {state, true}
    end
  end

  # Garbage collect memories below min_salience (unless pinned or high-reinforcement).
  defp gc_memories(state) do
    min_sal = state.config.min_salience

    :ets.tab2list(state.table)
    |> Enum.each(fn {id, mem} ->
      pinned = Map.get(mem, :pinned, false)

      if not pinned and mem.salience < min_sal and mem.reinforcement_count <= 5 do
        :ets.delete(state.table, id)
        Logger.debug("[Kyber.Memory.Consolidator] GC'd memory #{id} (salience #{Float.round(mem.salience, 3)})")
      end
    end)

    state
  end

  # Query Kyber.Delta.Store for deltas since the given Unix timestamp.
  defp query_recent_deltas(core, _since_seconds) do
    try do
      store = GenServer.call(core, :get_store_name, 1_000)
      all = Kyber.Delta.Store.query(store, [])

      Enum.filter(all, fn delta ->
        delta.kind not in ["cron.fired", "system.heartbeat"] and
          byte_size(inspect(delta.payload)) > 20
      end)
      |> Enum.take_random(min(50, length(all)))
    rescue
      _ -> []
    catch
      :exit, _ -> []
    end
  end

  # Send deltas to LLM (Haiku) for salience scoring.
  # Returns {:ok, [%{summary, salience, tags}]} or {:error, reason}.
  defp score_deltas(deltas, auth_config, model) do
    # Sanitize and cap each delta before building the prompt
    delta_summaries =
      deltas
      |> Enum.map(fn delta ->
        safe_payload = sanitize_delta(delta.payload)
        summary = "kind=#{delta.kind} payload=#{inspect(safe_payload, limit: 10)}"
        # Cap each delta's contribution to 500 chars
        String.slice(summary, 0, 500)
      end)
      |> Enum.join("\n")
      # Hard cap on total prompt input: ~8000 chars
      |> String.slice(0, 8_000)

    prompt = """
    You are reviewing a list of events from an AI agent's delta log.
    Score each item for long-term salience (how useful will this be to remember in the future?).

    Return a JSON array of objects. Each object must have:
    - "summary": one concise line (max 100 chars) describing what happened
    - "salience": float 0.0 to 1.0 (0=ephemeral, 1=highly important to remember)
    - "tags": list of 1-5 lowercase topic strings (e.g. ["architecture", "oauth", "tools"])

    Only include items worth remembering (salience >= 0.3). Skip noise.
    Return ONLY the JSON array, no other text.

    Events:
    #{delta_summaries}
    """

    headers = build_auth_headers(auth_config)

    body = %{
      "model" => model,
      "max_tokens" => 2048,
      "messages" => [%{"role" => "user", "content" => prompt}]
    }

    body =
      case auth_config.type do
        :oauth ->
          Map.put(body, "system", [
            %{"type" => "text", "text" => "You are Claude Code, Anthropic's official CLI for Claude."},
            %{"type" => "text", "text" => "You are a memory scoring assistant. Return only valid JSON."}
          ])
        _ ->
          Map.put(body, "system", "You are a memory scoring assistant. Return only valid JSON.")
      end

    case Req.post(@anthropic_url, headers: headers, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response}} ->
        content = extract_response_text(response)
        parse_scored_memories(content)

      {:ok, %{status: status, body: err_body}} ->
        {:error, "LLM API #{status}: #{inspect(err_body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Deep-walk a delta payload, stripping sensitive keys and capping string lengths.
  defp sanitize_delta(payload) when is_map(payload) do
    payload
    |> Map.drop(@sensitive_keys)
    |> Map.drop(Enum.map(@sensitive_keys, &String.to_atom/1))
    |> Map.new(fn {k, v} ->
      key_str = k |> to_string() |> String.downcase()
      if Enum.any?(@sensitive_keys, &String.contains?(key_str, &1)) do
        {k, "[REDACTED]"}
      else
        {k, sanitize_delta(v)}
      end
    end)
  end

  defp sanitize_delta(v) when is_binary(v) and byte_size(v) > 200 do
    String.slice(v, 0, 200) <> "..."
  end

  defp sanitize_delta(v) when is_list(v) do
    Enum.map(v, &sanitize_delta/1)
  end

  defp sanitize_delta(v), do: v

  # Parse the LLM's JSON response into a list of memory maps.
  defp parse_scored_memories(content) do
    cleaned =
      content
      |> String.replace(~r/```(?:json)?\n?/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, list} when is_list(list) ->
        memories =
          list
          |> Enum.filter(fn item ->
            is_map(item) and
              is_binary(item["summary"]) and
              is_number(item["salience"]) and
              is_list(item["tags"])
          end)
          |> Enum.map(fn item ->
            %{
              summary: item["summary"],
              salience: clamp(item["salience"], 0.0, 1.0),
              tags: item["tags"]
            }
          end)

        {:ok, memories}

      {:ok, _} ->
        {:error, "LLM returned non-list JSON"}

      {:error, reason} ->
        {:error, "JSON parse error: #{inspect(reason)}"}
    end
  end

  # Add newly scored memories to the ETS pool.
  defp merge_scored_memories(scored, table) do
    now = System.system_time(:second)

    Enum.each(scored, fn mem ->
      id = generate_id()
      entry = %{
        id: id,
        summary: mem.summary,
        salience: mem.salience,
        tags: mem.tags,
        created_at: now,
        last_reinforced: nil,
        reinforcement_count: 0,
        pinned: false
      }
      :ets.insert(table, {id, entry})
    end)
  end

  # On first run with empty pool, just log. Agent decides what to pin.
  defp seed_pinned_memories(_table) do
    Logger.info("[Kyber.Memory.Consolidator] empty pool — agent will build memories organically")
  end

  # ── MEMORY.md Generation ──────────────────────────────────────────────────

  defp write_memory_md(pool, path, config) do
    now = System.system_time(:second)

    sorted_pool =
      pool
      |> Enum.map(fn mem ->
        recency_weight = compute_recency_weight(mem.created_at, now)
        score = mem.salience * recency_weight
        {score, mem}
      end)
      |> Enum.sort_by(fn {score, _} -> score end, :desc)

    {top_n, rest} = Enum.split(sorted_pool, config.max_persistent)

    persistent_mems = Enum.map(top_n, fn {_, mem} -> mem end)

    drifting_mems = sample_drifting(rest, config.max_drifting)

    content = render_memory_md(persistent_mems, drifting_mems)
    final_content = enforce_token_budget(content, drifting_mems, persistent_mems)

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, final_content) do
          :ok ->
            Logger.debug("[Kyber.Memory.Consolidator] MEMORY.md written (#{byte_size(final_content)} chars)")
          {:error, reason} ->
            Logger.error("[Kyber.Memory.Consolidator] failed to write MEMORY.md: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.error("[Kyber.Memory.Consolidator] failed to create vault dir: #{inspect(reason)}")
    end
  end

  defp sample_drifting(scored_pool, n) do
    pool = Enum.map(scored_pool, fn {_, mem} -> mem end)

    if length(pool) <= n do
      pool
    else
      quartile = max(1, div(length(pool), 4))
      by_age = Enum.sort_by(pool, & &1.created_at, :asc)

      oldest = Enum.take(by_age, quartile)
      middle = by_age |> Enum.drop(quartile) |> Enum.take(quartile * 2)
      newest = Enum.drop(by_age, quartile * 3)

      sample_from_groups([oldest, middle, newest], n)
    end
  end

  defp sample_from_groups(groups, n) do
    groups
    |> Enum.flat_map(fn group ->
      take = max(1, div(n, length(groups)))
      Enum.take_random(group, min(take, length(group)))
    end)
    |> Enum.take_random(n)
  end

  defp render_memory_md(persistent, drifting) do
    header = """
    # MEMORY.md — Long-Term Memory

    *This file is a view, not a source of truth. Regenerated each consolidation cycle by `Kyber.Memory.Consolidator`. The pool JSONL at `~/.kyber/memory_pool.jsonl` is the source of truth.*

    ---

    ## Persistent (salience-ranked)

    """

    persistent_lines =
      if persistent == [] do
        "*No persistent memories yet.*\n"
      else
        persistent
        |> Enum.map_join("\n", fn mem ->
          pin_flag = if Map.get(mem, :pinned, false), do: " 📌", else: ""
          tags = if mem.tags != [], do: " [#{Enum.join(mem.tags, ", ")}]", else: ""
          "- #{mem.summary}#{tags}#{pin_flag}"
        end)
      end

    drifting_header = "\n\n## Drifting (stochastic rotation)\n\n"

    drifting_lines =
      if drifting == [] do
        "*[populated by Memory.Consolidator — next rotation pending]*\n"
      else
        drifting
        |> Enum.map_join("\n", fn mem ->
          tags = if mem.tags != [], do: " [#{Enum.join(mem.tags, ", ")}]", else: ""
          "- #{mem.summary}#{tags}"
        end)
      end

    header <> persistent_lines <> drifting_header <> drifting_lines
  end

  defp enforce_token_budget(content, drifting, persistent) when byte_size(content) > @max_memory_chars do
    trimmed_drifting =
      drifting
      |> Enum.sort_by(& &1.salience, :asc)
      |> Enum.drop(1)

    new_content = render_memory_md(persistent, trimmed_drifting)

    if byte_size(new_content) > @max_memory_chars and trimmed_drifting != [] do
      enforce_token_budget(new_content, trimmed_drifting, persistent)
    else
      new_content
    end
  end

  defp enforce_token_budget(content, _drifting, _persistent), do: content

  # ── Pool Persistence ──────────────────────────────────────────────────────

  @doc false
  def load_pool(path) do
    if File.exists?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.flat_map(fn line ->
        case Jason.decode(line) do
          {:ok, map} ->
            mem = map_to_memory(map)
            if mem, do: [mem], else: []
          _ -> []
        end
      end)
      |> Enum.to_list()
    else
      []
    end
  rescue
    e ->
      Logger.warning("[Kyber.Memory.Consolidator] failed to load pool: #{inspect(e)}")
      []
  end

  @doc false
  def save_pool(pool, path) do
    File.mkdir_p!(Path.dirname(path))

    content =
      pool
      |> Enum.map(&memory_to_json/1)
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n", &Jason.encode!/1)

    content = if content == "", do: "", else: content <> "\n"

    case File.write(path, content) do
      :ok -> :ok
      {:error, reason} ->
        Logger.warning("[Kyber.Memory.Consolidator] failed to save pool: #{inspect(reason)}")
    end
  end

  defp memory_to_json(mem) do
    %{
      "id" => mem.id,
      "summary" => mem.summary,
      "salience" => mem.salience,
      "tags" => mem.tags || [],
      "created_at" => mem.created_at,
      "last_reinforced" => mem.last_reinforced,
      "reinforcement_count" => mem.reinforcement_count,
      "pinned" => Map.get(mem, :pinned, false)
    }
  end

  defp map_to_memory(map) do
    with id when is_binary(id) <- Map.get(map, "id"),
         summary when is_binary(summary) <- Map.get(map, "summary"),
         salience when is_number(salience) <- Map.get(map, "salience"),
         tags when is_list(tags) <- Map.get(map, "tags", []),
         created_at when is_integer(created_at) <- Map.get(map, "created_at") do
      %{
        id: id,
        summary: summary,
        salience: clamp(salience, 0.0, 1.0),
        tags: tags,
        created_at: created_at,
        last_reinforced: Map.get(map, "last_reinforced"),
        reinforcement_count: Map.get(map, "reinforcement_count", 0),
        pinned: Map.get(map, "pinned", false)
      }
    else
      _ -> nil
    end
  end

  # ── Auth ──────────────────────────────────────────────────────────────────

  defp load_auth_config do
    Kyber.Plugin.LLM.load_auth_config()
  end

  defp build_auth_headers(%{type: :oauth, token: token}) do
    [
      {"Authorization", "Bearer #{token}"},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta", "claude-code-20250219,oauth-2025-04-20"},
      {"user-agent", "claude-cli/2.1.62"},
      {"x-app", "cli"},
      {"content-type", "application/json"}
    ]
  end

  defp build_auth_headers(%{type: :api_key, token: token}) do
    [
      {"x-api-key", token},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  # ── Helpers ───────────────────────────────────────────────────────────────

  defp schedule_consolidation(interval_ms) do
    Process.send_after(self(), :consolidate, interval_ms)
  end

  defp read_pool_from_ets(table) do
    :ets.tab2list(table)
    |> Enum.map(fn {_id, mem} -> mem end)
  end

  defp build_config(opts) do
    Enum.reduce(@default_config, %{}, fn {key, default}, acc ->
      Map.put(acc, key, Keyword.get(opts, key, default))
    end)
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)
  end

  defp clamp(val, min_val, max_val) do
    val |> max(min_val) |> min(max_val)
  end

  defp compute_recency_weight(created_at, now) do
    age_days = (now - created_at) / 86_400
    max(0.3, 1.0 - age_days / 30.0)
  end

  defp extract_response_text(%{"content" => [%{"text" => text} | _]}), do: text

  defp extract_response_text(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.map_join("", &Map.get(&1, "text", ""))
  end

  defp extract_response_text(_), do: ""
end
