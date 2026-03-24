defmodule Kyber.Session do
  @moduledoc """
  Conversation history management for Kyber.

  Sessions are keyed by `chat_id` (derived from a delta's origin) and store
  an ordered list of message deltas for that conversation.

  History is stored in ETS for fast concurrent reads. The GenServer serialises
  writes so there are no race conditions when appending messages.

  ## Session Rehydration

  On startup, if a `delta_store` is provided, the Session GenServer queries
  historical `message.received` and `llm.response` deltas from the store and
  rebuilds conversation history. This ensures context survives process restarts.

  Rehydration is done synchronously inside `init/1` so that the session is
  fully populated before `start_link/1` returns. This is safe because
  `Kyber.Core` (and its `Delta.Store`) starts before `Kyber.Session` in the
  application supervision tree.

  ## Usage

      {:ok, pid} = Kyber.Session.start_link()

      Kyber.Session.add_message(pid, "chat_1", delta)
      history = Kyber.Session.get_history(pid, "chat_1")
      Kyber.Session.clear(pid, "chat_1")
      sessions = Kyber.Session.list_sessions(pid)
  """

  use GenServer
  require Logger

  # Kinds persisted to the delta store that we use to rebuild session history.
  @rehydration_kinds ~w(message.received llm.response)

  # Default maximum number of messages kept per chat_id.
  @default_max_history 100

  # Default TTL for stale session cleanup (milliseconds). Sessions with no
  # write activity for longer than this are eligible for sweeping.
  @default_stale_ttl_ms :timer.hours(1)

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the Session GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Return the configured max_history for this session server.
  """
  @spec max_history(GenServer.server()) :: pos_integer()
  def max_history(pid \\ __MODULE__) do
    GenServer.call(pid, :get_max_history)
  end

  @doc "Return the message history for a given chat_id."
  @spec get_history(GenServer.server(), String.t()) :: [Kyber.Delta.t()]
  def get_history(pid \\ __MODULE__, chat_id) when is_binary(chat_id) do
    table = table_name(pid)

    # Guard against the ETS table not existing (e.g. Session GenServer is between
    # crash and restart). Returns [] rather than raising :badarg.
    #
    # History is stored newest-first (prepend on write) for O(1) appends.
    # We reverse here so callers always receive chronological order (oldest first).
    try do
      case :ets.lookup(table, chat_id) do
        [{^chat_id, history}] -> Enum.reverse(history)
        [] -> []
      end
    rescue
      ArgumentError -> []
    end
  end

  @doc "Append a delta to the history for a chat_id."
  @spec add_message(GenServer.server(), String.t(), Kyber.Delta.t()) :: :ok
  def add_message(pid \\ __MODULE__, chat_id, %Kyber.Delta{} = delta)
      when is_binary(chat_id) do
    GenServer.call(pid, {:add_message, chat_id, delta})
  end

  @doc "Clear the history for a chat_id."
  @spec clear(GenServer.server(), String.t()) :: :ok
  def clear(pid \\ __MODULE__, chat_id) when is_binary(chat_id) do
    GenServer.call(pid, {:clear, chat_id})
  end

  @doc "List all chat_ids that have active sessions."
  @spec list_sessions(GenServer.server()) :: [String.t()]
  def list_sessions(pid \\ __MODULE__) do
    table = table_name(pid)
    :ets.tab2list(table) |> Enum.map(fn {chat_id, _} -> chat_id end)
  end

  @doc """
  Remove sessions that have been inactive longer than `ttl_ms` milliseconds.

  Returns the list of chat_ids that were swept.
  """
  @spec sweep_stale(GenServer.server(), pos_integer()) :: [String.t()]
  def sweep_stale(pid \\ __MODULE__, ttl_ms \\ @default_stale_ttl_ms) do
    GenServer.call(pid, {:sweep_stale, ttl_ms})
  end

  @doc """
  Return the last-write timestamp (epoch ms) for a chat_id, or `nil` if unknown.
  """
  @spec last_active(GenServer.server(), String.t()) :: integer() | nil
  def last_active(pid \\ __MODULE__, chat_id) when is_binary(chat_id) do
    GenServer.call(pid, {:last_active, chat_id})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    table = :"#{name}.Sessions"
    max_history = Keyword.get(opts, :max_history, @default_max_history)
    # :protected allows concurrent reads from any process (fast path for get_history)
    # while restricting writes to the owning GenServer (ordering guarantee).
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    delta_store = Keyword.get(opts, :delta_store, nil)
    rehydrate_from_store(table, delta_store)

    # Build initial activity map from rehydrated sessions.
    now = System.system_time(:millisecond)
    activity =
      :ets.tab2list(table)
      |> Enum.into(%{}, fn {chat_id, _msgs} -> {chat_id, now} end)

    Logger.info("[Kyber.Session] started (table: #{table}, max_history: #{max_history})")
    {:ok, %{table: table, delta_store: delta_store, max_history: max_history, activity: activity}}
  end

  @impl true
  def handle_call({:add_message, chat_id, delta}, _from, %{table: table, max_history: max_history} = state) do
    history =
      case :ets.lookup(table, chat_id) do
        [{^chat_id, existing}] -> existing
        [] -> []
      end

    # Prepend instead of append for O(1) writes. get_history/2 reverses on read.
    updated = [delta | history]

    # Cap the history length. History is stored newest-first, so dropping from
    # the tail trims the oldest messages.
    capped =
      if length(updated) > max_history do
        Enum.take(updated, max_history)
      else
        updated
      end

    :ets.insert(table, {chat_id, capped})

    # Track last-write activity for stale session sweeping.
    activity = Map.put(state.activity, chat_id, System.system_time(:millisecond))
    {:reply, :ok, %{state | activity: activity}}
  end

  def handle_call({:clear, chat_id}, _from, %{table: table} = state) do
    :ets.delete(table, chat_id)
    activity = Map.delete(state.activity, chat_id)
    {:reply, :ok, %{state | activity: activity}}
  end

  def handle_call(:get_table, _from, %{table: table} = state) do
    {:reply, table, state}
  end

  def handle_call(:get_max_history, _from, state) do
    {:reply, state.max_history, state}
  end

  def handle_call({:last_active, chat_id}, _from, state) do
    {:reply, Map.get(state.activity, chat_id), state}
  end

  def handle_call({:sweep_stale, ttl_ms}, _from, %{table: table, activity: activity} = state) do
    now = System.system_time(:millisecond)
    cutoff = now - ttl_ms

    {stale_ids, kept_activity} =
      Enum.reduce(activity, {[], %{}}, fn {chat_id, last_ts}, {stale, kept} ->
        if last_ts < cutoff do
          {[chat_id | stale], kept}
        else
          {stale, Map.put(kept, chat_id, last_ts)}
        end
      end)

    Enum.each(stale_ids, fn chat_id ->
      :ets.delete(table, chat_id)
    end)

    if stale_ids != [] do
      Logger.info("[Kyber.Session] swept #{length(stale_ids)} stale session(s): #{inspect(stale_ids)}")
    end

    {:reply, stale_ids, %{state | activity: kept_activity}}
  end

  @impl true
  def terminate(reason, state) do
    Logger.info("[Kyber.Session] terminating: #{inspect(reason)}")
    :ets.delete(state.table)
    :ok
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  # Query the delta store and populate ETS with historical conversation history.
  # Called synchronously from init/1 so the session is fully ready before
  # start_link/1 returns. No-ops if delta_store is nil.
  defp rehydrate_from_store(_table, nil), do: :ok

  defp rehydrate_from_store(table, store) do
    Logger.info("[Kyber.Session] rehydrating from #{inspect(store)}")

    try do
      history_by_chat =
        @rehydration_kinds
        |> Enum.flat_map(fn kind ->
          Kyber.Delta.Store.query(store, kind: kind)
        end)
        |> Enum.sort_by(& &1.ts)
        |> Enum.flat_map(&to_session_entry/1)
        |> Enum.group_by(fn {chat_id, _delta} -> chat_id end)

      Enum.each(history_by_chat, fn {chat_id, entries} ->
        sorted =
          entries
          |> Enum.sort_by(fn {_cid, d} -> d.ts end)
          |> Enum.map(fn {_cid, d} -> d end)

        # Store newest-first to match the prepend strategy used by add_message/3.
        # get_history/2 will reverse before returning to callers.
        :ets.insert(table, {chat_id, Enum.reverse(sorted)})
        Logger.debug("[Kyber.Session] rehydrated #{length(sorted)} messages for chat #{chat_id}")
      end)

      total = Enum.reduce(history_by_chat, 0, fn {_, entries}, acc -> acc + length(entries) end)
      Logger.info("[Kyber.Session] rehydrated #{total} messages across #{map_size(history_by_chat)} sessions")
    rescue
      e ->
        Logger.error(
          "[Kyber.Session] rehydration failed: #{inspect(e)}\n" <>
            Exception.format_stacktrace(__STACKTRACE__)
        )
    end

    :ok
  end

  # Convert a persisted delta to zero or one {chat_id, session_delta} pair.
  # We rebuild in the same format that the LLM plugin stores at runtime so
  # that history reads by Kyber.Plugin.LLM are uniform regardless of origin.
  defp to_session_entry(%Kyber.Delta{kind: "message.received"} = delta) do
    case chat_id_from_origin(delta.origin) do
      nil -> []
      chat_id ->
        text = Map.get(delta.payload, "text", "")
        session_delta = %Kyber.Delta{
          delta
          | kind: "session.user",
            payload: %{"role" => "user", "content" => text}
        }
        [{chat_id, session_delta}]
    end
  end

  defp to_session_entry(%Kyber.Delta{kind: "llm.response"} = delta) do
    case chat_id_from_origin(delta.origin) do
      nil -> []
      chat_id ->
        content = Map.get(delta.payload, "content", "")
        session_delta = %Kyber.Delta{
          delta
          | kind: "session.assistant",
            payload: %{"role" => "assistant", "content" => content}
        }
        [{chat_id, session_delta}]
    end
  end

  defp to_session_entry(_delta), do: []

  # Mirror the chat_id extraction logic from Kyber.Plugin.LLM so rehydration
  # uses the same rules as live message handling.
  defp chat_id_from_origin({:channel, _ch, chat_id, _sender}), do: chat_id
  defp chat_id_from_origin({:human, user_id}), do: user_id
  defp chat_id_from_origin(_), do: nil

  # Get the ETS table name for a given pid/name.
  defp table_name(pid) when is_pid(pid) do
    case Process.info(pid, :registered_name) do
      {:registered_name, name} when is_atom(name) and name != [] ->
        :"#{name}.Sessions"
      _ ->
        # Fall back to GenServer call for unnamed pids
        GenServer.call(pid, :get_table)
    end
  end

  defp table_name(name) when is_atom(name), do: :"#{name}.Sessions"
end
