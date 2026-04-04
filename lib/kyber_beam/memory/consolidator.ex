defmodule Kyber.Memory.Consolidator do
  @moduledoc """
  Long-term memory management — salience layer over the Knowledge graph.

  Pool entries are **pointers to vault notes** with salience metadata.
  No content is duplicated here: summaries come from Knowledge L0/L1 tiers
  on demand when MEMORY.md is generated.

  ## Pool Entry Structure

  Each entry in the pool (ETS + JSONL) has:
  - `id` — unique binary ID
  - `vault_ref` — path relative to vault root (e.g. "concepts/reducer-purity.md")
  - `salience` — 0.0–1.0 score, adjusted by reinforcement/decay
  - `tags` — list of topic tags from note frontmatter or LLM scoring
  - `pinned` — if true, never decays or gets GC'd
  - `created_at` — Unix timestamp
  - `last_reinforced` — Unix timestamp of last reinforcement (nil if never)
  - `reinforcement_count` — how many times this memory has been reinforced

  ## Vault Change Scoring

  On init, subscribes to `Kyber.Knowledge`. When vault files change,
  `handle_info({:vault_changed, paths})` fires and each changed path is scored
  individually via a Haiku call: "should this note be in long-term memory?"
  Only changed/new notes are scored — never the whole vault.

  ## Periodic Consolidation

  Every hour (default):
  1. Apply buffered reinforcements
  2. Decay unreinforced memories (salience × 0.95)
  3. GC low-salience entries + dead vault refs (note deleted from vault)
  4. Rebuild MEMORY.md from pool (content pulled from Knowledge L0 tiers)
  5. Persist pool to JSONL

  Scoring is NOT done in the periodic cycle — it is event-driven from vault changes.

  ## Reinforcement

  When memory tags appear in an LLM response, call `reinforce/1`. Tags are
  buffered and applied atomically at the start of the next consolidation cycle.

  ## MEMORY.md Structure

  - Persistent section: top 8 by salience × recency, rendered as L0 titles
  - Drifting section: random 8, rendered as L0 titles
  - Pinned memories get 📌 prefix
  - Dead refs (vault note deleted) are skipped automatically
  - Token budget: capped at ~8000 chars; lowest-salience drifting dropped first

  ## Architecture Note

  MEMORY.md is a *view*. The pool JSONL is the *source of truth*. The vault
  notes are the *content source*. This three-layer design avoids duplication:
  salience is separate from knowledge; neither modifies the other.
  """

  use GenServer
  require Logger

  @default_config %{
    consolidation_interval_ms: 3_600_000,
    max_persistent: 8,
    max_drifting: 8,
    salience_model: "claude-sonnet-4-20250514",
    decay_rate: 0.95,
    reinforcement_bump: 0.1,
    min_salience: 0.05
  }

  @pool_path "~/.kyber/memory_pool.jsonl"
  @legacy_memory_md_path "~/.kyber/vault/identity/MEMORY.md"
  @anthropic_url "https://api.anthropic.com/v1/messages"
  @max_memory_chars 8_000

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
    memory_md_path = Keyword.get(opts, :memory_md_path, default_memory_md_path()) |> Path.expand()
    core = Keyword.get(opts, :core, Kyber.Core)
    knowledge = Keyword.get(opts, :knowledge, Kyber.Knowledge)

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

    # Named ETS tables are automatically deleted when their owning process dies,
    # so after a crash+restart :ets.whereis will return :undefined. We always
    # create a fresh table. If a table with this name somehow still exists
    # (e.g. race during rapid restarts), delete it first to avoid :badarg.
    if :ets.whereis(table_name) != :undefined do
      try do
        :ets.delete(table_name)
      rescue
        _ -> :ok
      catch
        _, _ -> :ok
      end
    end

    table = :ets.new(table_name, [:named_table, :set, :protected, read_concurrency: true])

    # Populate ETS from loaded pool
    Enum.each(pool, fn mem -> :ets.insert(table, {mem.id, mem}) end)

    # Subscribe to vault changes and monitor Knowledge (graceful if not yet running)
    knowledge_monitored =
      if pid = Process.whereis(knowledge) do
        Process.monitor(pid)
        Kyber.Knowledge.subscribe(knowledge)
        true
      else
        false
      end

    state = %{
      config: config,
      pool_path: pool_path,
      memory_md_path: memory_md_path,
      core: core,
      knowledge: knowledge,
      table: table,
      last_consolidated: nil,
      pending_reinforcements: [],
      knowledge_monitored: knowledge_monitored,
      scoring_in_progress: false,
      pending_paths: []
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
  # Scoring already in progress — buffer paths for the next batch (debounce)
  def handle_info({:vault_changed, paths}, %{scoring_in_progress: true} = state) do
    pending = Enum.uniq(state.pending_paths ++ paths)
    {:noreply, %{state | pending_paths: pending}}
  end

  # Start async scoring Task; GenServer remains responsive during HTTP calls
  def handle_info({:vault_changed, paths}, state) do
    server = self()
    knowledge = state.knowledge
    model = state.config.salience_model

    case load_auth_config() do
      {:ok, auth} ->
        Task.start(fn ->
          try do
            results = score_paths_for_task(paths, auth, knowledge, model)
            send(server, {:scoring_complete, results})
          rescue
            e ->
              Logger.error("[Kyber.Memory.Consolidator] scoring task crashed: #{inspect(e)}")
              send(server, {:scoring_complete, []})
          catch
            kind, reason ->
              Logger.error("[Kyber.Memory.Consolidator] scoring task #{kind}: #{inspect(reason)}")
              send(server, {:scoring_complete, []})
          end
        end)

        {:noreply, %{state | scoring_in_progress: true, pending_paths: []}}

      {:error, reason} ->
        Logger.debug("[Kyber.Memory.Consolidator] no auth for vault note scoring: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Task finished — merge results into ETS (GenServer owns all writes)
  def handle_info({:scoring_complete, results}, state) do
    Enum.each(results, fn {vault_ref, salience, tags} ->
      merge_vault_scored(vault_ref, salience, tags, state.table)
    end)

    # If paths accumulated while scoring was in progress, start the next batch
    if state.pending_paths != [] do
      server = self()
      pending = state.pending_paths
      knowledge = state.knowledge
      model = state.config.salience_model

      case load_auth_config() do
        {:ok, auth} ->
          Task.start(fn ->
            try do
              results = score_paths_for_task(pending, auth, knowledge, model)
              send(server, {:scoring_complete, results})
            rescue
              e ->
                Logger.error("[Kyber.Memory.Consolidator] pending scoring crashed: #{inspect(e)}")
                send(server, {:scoring_complete, []})
            catch
              kind, reason ->
                Logger.error("[Kyber.Memory.Consolidator] pending scoring #{kind}: #{inspect(reason)}")
                send(server, {:scoring_complete, []})
            end
          end)

          {:noreply, %{state | scoring_in_progress: true, pending_paths: []}}

        {:error, _} ->
          {:noreply, %{state | scoring_in_progress: false, pending_paths: []}}
      end
    else
      {:noreply, %{state | scoring_in_progress: false}}
    end
  end

  # Knowledge process went down — clear monitor flag and schedule resubscribe
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, state) do
    Logger.info("[Kyber.Memory.Consolidator] Knowledge went down — will resubscribe on restart")
    Process.send_after(self(), :resubscribe_knowledge, 5_000)
    {:noreply, %{state | knowledge_monitored: false}}
  end

  # Retry subscribing to Knowledge (handles late-start and restart scenarios)
  def handle_info(:resubscribe_knowledge, state) do
    if pid = Process.whereis(state.knowledge) do
      Process.monitor(pid)
      Kyber.Knowledge.subscribe(state.knowledge)
      Logger.info("[Kyber.Memory.Consolidator] re-subscribed to Knowledge after restart")
      {:noreply, %{state | knowledge_monitored: true}}
    else
      # Still not running — retry in 5 seconds
      Process.send_after(self(), :resubscribe_knowledge, 5_000)
      {:noreply, state}
    end
  end

  def handle_info(:consolidate, state) do
    new_state = run_consolidation(state)
    schedule_consolidation(state.config.consolidation_interval_ms)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Consolidation Cycle ────────────────────────────────────────────────────

  defp run_consolidation(state) do
    Logger.info("[Kyber.Memory.Consolidator] starting consolidation cycle")

    # Opportunistically resubscribe to Knowledge if not currently monitoring
    state =
      if not state.knowledge_monitored do
        if pid = Process.whereis(state.knowledge) do
          Process.monitor(pid)
          Kyber.Knowledge.subscribe(state.knowledge)
          Logger.info("[Kyber.Memory.Consolidator] subscribed to Knowledge during consolidation cycle")
          %{state | knowledge_monitored: true}
        else
          state
        end
      else
        state
      end

    # 0. Apply buffered reinforcements FIRST (single-process, no race)
    state = apply_pending_reinforcements(state)

    # 1. Apply decay to all existing memories (skipping pinned + recently reinforced)
    state = apply_decay(state)

    # 2. Garbage collect low-salience entries and dead vault refs
    state = gc_memories(state)

    # 3. Rebuild MEMORY.md from pool (content pulled from Knowledge)
    pool = read_pool_from_ets(state.table)
    write_memory_md(pool, state.memory_md_path, state.config, state.knowledge)

    # 4. Persist pool to JSONL
    save_pool(read_pool_from_ets(state.table), state.pool_path)

    %{state | last_consolidated: DateTime.utc_now()}
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

  # Garbage collect:
  # - Dead vault refs (note deleted from vault), unless Knowledge is not running
  # - Low-salience memories below min threshold (not pinned, not heavily reinforced)
  defp gc_memories(state) do
    min_sal = state.config.min_salience
    knowledge = state.knowledge

    :ets.tab2list(state.table)
    |> Enum.each(fn {id, mem} ->
      pinned = Map.get(mem, :pinned, false)
      vault_ref = Map.get(mem, :vault_ref)

      cond do
        # Dead vault ref: vault note was deleted (only when not pinned, Knowledge must be running)
        vault_ref != nil and not pinned and not safe_vault_ref_exists?(knowledge, vault_ref) ->
          :ets.delete(state.table, id)
          Logger.debug("[Kyber.Memory.Consolidator] removed dead ref #{vault_ref}")

        # Low-salience GC: unpinned, below threshold, low reinforcement count
        not pinned and mem.salience < min_sal and mem.reinforcement_count <= 5 ->
          :ets.delete(state.table, id)
          Logger.debug("[Kyber.Memory.Consolidator] GC'd memory #{id} (salience #{Float.round(mem.salience, 3)})")

        true ->
          :ok
      end
    end)

    state
  end

  # Check if a vault ref still exists in Knowledge.
  # Returns true if Knowledge is not running (graceful: don't GC on outage).
  defp safe_vault_ref_exists?(knowledge, vault_ref) do
    try do
      case GenServer.call(knowledge, {:get_tiered, vault_ref, :l0}, 2_000) do
        {:ok, _} -> true
        {:error, :not_found} -> false
      end
    catch
      :exit, _ ->
        # Knowledge not running — assume ref is alive to avoid false GC
        true
    end
  end

  # ── Vault Change Scoring ───────────────────────────────────────────────────

  # Called from a background Task — scores all paths and returns a list of
  # {vault_ref, salience, tags} tuples. No ETS writes happen here.
  defp score_paths_for_task(paths, auth, knowledge, model) do
    Logger.info("[Kyber.Memory.Consolidator] scoring #{length(Enum.uniq(paths))} paths")

    paths
    |> Enum.uniq()
    |> Enum.flat_map(fn path ->
      Logger.debug("[Kyber.Memory.Consolidator] scoring path: #{path}")

      case score_path_to_result(path, auth, knowledge, model) do
        {:ok, vault_ref, salience, tags} ->
          tags_summary = tag_summary(tags)
          Logger.info("[Kyber.Memory.Consolidator] scored #{vault_ref}: salience=#{salience}, tags=#{tags_summary}")
          [{vault_ref, salience, tags}]

        :error ->
          Logger.warning("[Kyber.Memory.Consolidator] score returned :error for #{path}")
          []
      end
    end)
  end

  # Score a single vault note; returns {:ok, vault_ref, salience, tags} or :error.
  # Safe to call from a Task — only reads from Knowledge, no ETS writes.
  defp score_path_to_result(vault_ref, auth, knowledge, model) do
    l1_content =
      case safe_knowledge_get_tiered(knowledge, vault_ref, :l1) do
        {:ok, %{frontmatter: fm, first_paragraph: para}} ->
          title = Map.get(fm, "title", Path.basename(vault_ref, ".md"))
          tags = Map.get(fm, "tags", [])
          tag_line = if tags != [], do: "Tags: #{Enum.join(tags, ", ")}\n", else: ""
          "Title: #{title}\n#{tag_line}#{para}"

        _ ->
          nil
      end

    if l1_content do
      case score_vault_note(vault_ref, l1_content, auth, model) do
        {:ok, %{salience: salience, tags: tags}} ->
          {:ok, vault_ref, salience, tags}

        {:error, reason} ->
          Logger.warning("[Kyber.Memory.Consolidator] failed to score #{vault_ref}: #{inspect(reason)}")
          :error
      end
    else
      :error
    end
  end

  # Call Haiku to score a single vault note for long-term salience.
  # Returns {:ok, %{salience: float, tags: [string]}} or {:error, reason}.
  defp score_vault_note(vault_ref, l1_content, auth_config, model) do
    prompt = """
    You are evaluating a vault note for long-term memory salience.

    Score how useful this note will be to remember in the future.

    Return a JSON object with exactly these fields:
    - "salience": float 0.0 to 1.0 (0=ephemeral/temporary, 1=highly important to remember)
    - "tags": list of 1-5 lowercase topic strings (e.g. ["architecture", "auth", "elixir"])

    Return ONLY the JSON object, no other text.

    Note path: #{vault_ref}
    Note content:
    #{String.slice(l1_content, 0, 2_000)}
    """

    headers = build_auth_headers(auth_config)

    body = %{
      "model" => model,
      "max_tokens" => 256,
      "messages" => [%{"role" => "user", "content" => prompt}]
    }

    body =
      case auth_config.type do
        :oauth ->
          Map.put(body, "system", [
            %{"type" => "text", "text" => "You are Claude Code, Anthropic's official CLI for Claude."},
            %{"type" => "text", "text" => "You are a memory salience scorer. Return only valid JSON."}
          ])

        _ ->
          Map.put(body, "system", "You are a memory salience scorer. Return only valid JSON.")
      end

    case Req.post(@anthropic_url, headers: headers, json: body, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: response}} ->
        content = extract_response_text(response)
        parse_vault_score(content)

      {:ok, %{status: status, body: err_body}} ->
        {:error, "LLM API #{status}: #{inspect(err_body)}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Parse the LLM's JSON response into a salience score + tags.
  defp parse_vault_score(content) do
    cleaned =
      content
      |> String.replace(~r/```(?:json)?\n?/, "")
      |> String.trim()

    case Jason.decode(cleaned) do
      {:ok, %{"salience" => salience, "tags" => tags}}
      when is_number(salience) and is_list(tags) ->
        {:ok, %{salience: clamp(salience, 0.0, 1.0), tags: tags}}

      {:ok, _} ->
        {:error, "unexpected JSON structure"}

      {:error, reason} ->
        {:error, "JSON parse error: #{inspect(reason)}"}
    end
  end

  # Merge a scored vault note into the ETS pool.
  # - salience < 0.3 → remove existing entry if any (not salient enough)
  # - existing entry → update tags
  # - new salient note → create entry
  defp merge_vault_scored(vault_ref, salience, tags, table) do
    now = System.system_time(:second)
    existing = find_by_vault_ref(table, vault_ref)

    cond do
      salience < 0.3 ->
        if existing, do: :ets.delete(table, existing.id)

      existing ->
        # Only update tags; salience changes via decay/reinforcement mechanics
        updated = %{existing | tags: tags}
        :ets.insert(table, {existing.id, updated})
        Logger.debug("[Kyber.Memory.Consolidator] updated pool entry for #{vault_ref}")

      true ->
        id = generate_id()
        entry = %{
          id: id,
          vault_ref: vault_ref,
          salience: salience,
          tags: tags,
          created_at: now,
          last_reinforced: nil,
          reinforcement_count: 0,
          pinned: false
        }
        :ets.insert(table, {id, entry})
        Logger.info("[Kyber.Memory.Consolidator] added pool entry for #{vault_ref} (salience #{Float.round(salience, 2)})")
    end
  end

  # Find a pool entry by vault_ref (linear scan; pool is small).
  defp find_by_vault_ref(table, vault_ref) do
    :ets.tab2list(table)
    |> Enum.find_value(fn {_id, mem} ->
      if Map.get(mem, :vault_ref) == vault_ref, do: mem, else: nil
    end)
  end

  # ── MEMORY.md Generation ──────────────────────────────────────────────────

  defp write_memory_md(pool, path, config, knowledge) do
    if Process.whereis(knowledge) do
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

      content = render_memory_md(persistent_mems, drifting_mems, knowledge)
      final_content = enforce_token_budget(content, drifting_mems, persistent_mems, knowledge)

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
    else
      Logger.warning("[Kyber.Memory.Consolidator] Knowledge not running — skipping MEMORY.md regeneration to preserve previous version")
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

  defp render_memory_md(persistent, drifting, knowledge) do
    header = """
    # MEMORY.md — Long-Term Memory

    *This file is a view, not a source of truth. Regenerated each consolidation cycle by `Kyber.Memory.Consolidator`. The pool JSONL at `~/.kyber/memory_pool.jsonl` is the source of truth. Content comes from the Knowledge vault.*

    ---

    ## Persistent (salience-ranked)

    """

    persistent_lines =
      if persistent == [] do
        "*No persistent memories yet.*\n"
      else
        lines =
          persistent
          |> Enum.map(fn mem -> memory_line(mem, knowledge) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        if lines == "", do: "*No persistent memories yet.*\n", else: lines
      end

    drifting_header = "\n\n## Drifting (stochastic rotation)\n\n"

    drifting_lines =
      if drifting == [] do
        "*[populated by Memory.Consolidator — next rotation pending]*\n"
      else
        lines =
          drifting
          |> Enum.map(fn mem -> memory_line(mem, knowledge) end)
          |> Enum.reject(&is_nil/1)
          |> Enum.join("\n")

        if lines == "",
          do: "*[populated by Memory.Consolidator — next rotation pending]*\n",
          else: lines
      end

    header <> persistent_lines <> drifting_header <> drifting_lines
  end

  # Render a single memory as a MEMORY.md line, fetching title from Knowledge L0.
  # Returns nil if the vault ref is dead (note deleted).
  defp memory_line(mem, knowledge) do
    vault_ref = Map.get(mem, :vault_ref, "")

    case safe_knowledge_get_tiered(knowledge, vault_ref, :l0) do
      {:ok, %{title: title, tags: _fm_tags}} ->
        pin_flag = if Map.get(mem, :pinned, false), do: " 📌", else: ""
        # Prefer pool tags (may include LLM-scored terms beyond frontmatter)
        display_tags = mem.tags || []
        tag_str = if display_tags != [], do: " [#{Enum.join(display_tags, ", ")}]", else: ""
        "- #{title}#{tag_str}#{pin_flag}"

      _ ->
        # Dead ref or Knowledge not running — skip this line
        nil
    end
  end

  # Call Knowledge GenServer safely (no crash if not running).
  defp safe_knowledge_get_tiered(knowledge, vault_ref, tier) do
    try do
      GenServer.call(knowledge, {:get_tiered, vault_ref, tier}, 2_000)
    catch
      :exit, _ -> {:error, :not_running}
    end
  end

  defp enforce_token_budget(content, drifting, persistent, knowledge)
       when byte_size(content) > @max_memory_chars do
    trimmed_drifting =
      drifting
      |> Enum.sort_by(& &1.salience, :asc)
      |> Enum.drop(1)

    new_content = render_memory_md(persistent, trimmed_drifting, knowledge)

    if byte_size(new_content) > @max_memory_chars and trimmed_drifting != [] do
      enforce_token_budget(new_content, trimmed_drifting, persistent, knowledge)
    else
      new_content
    end
  end

  defp enforce_token_budget(content, _drifting, _persistent, _knowledge), do: content

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

          _ ->
            []
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
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[Kyber.Memory.Consolidator] failed to save pool: #{inspect(reason)}")
    end
  end

  defp memory_to_json(mem) do
    %{
      "id" => mem.id,
      "vault_ref" => Map.get(mem, :vault_ref, ""),
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
         vault_ref when is_binary(vault_ref) <- Map.get(map, "vault_ref"),
         salience when is_number(salience) <- Map.get(map, "salience"),
         tags when is_list(tags) <- Map.get(map, "tags", []),
         created_at when is_integer(created_at) <- Map.get(map, "created_at") do
      %{
        id: id,
        vault_ref: vault_ref,
        salience: clamp(salience, 0.0, 1.0),
        tags: tags,
        created_at: created_at,
        last_reinforced: Map.get(map, "last_reinforced"),
        reinforcement_count: Map.get(map, "reinforcement_count", 0),
        pinned: Map.get(map, "pinned", false)
      }
    else
      _ ->
        if Map.has_key?(map, "summary") do
          Logger.warning(
            "[Kyber.Memory.Consolidator] dropping legacy pool entry #{Map.get(map, "id", "?")} — " <>
              "has 'summary' but no 'vault_ref'. Run migration."
          )
        end

        nil
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

  defp tag_summary(tags) when is_list(tags) do
    case length(tags) do
      0 ->
        "[]"

      count when count <= 5 ->
        inspect(tags)

      count ->
        first_5 = Enum.take(tags, 5)
        "#{inspect(first_5)} (+#{count - 5} more, #{count} total)"
    end
  end

  defp tag_summary(tags), do: inspect(tags)

  defp default_memory_md_path do
    vault_dir = Path.expand("~/.kyber/vault")
    agent_name = try do
      Kyber.Config.get(:agent_name, "stilgar")
    rescue
      _ -> "stilgar"
    end

    case Kyber.Knowledge.detect_vault_layout(vault_dir) do
      :multi_agent ->
        Path.join([vault_dir, "agents", agent_name, "MEMORY.md"])

      :legacy ->
        @legacy_memory_md_path
    end
  end
end
