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

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the Session GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Return the message history for a given chat_id."
  @spec get_history(GenServer.server(), String.t()) :: [Kyber.Delta.t()]
  def get_history(pid \\ __MODULE__, chat_id) when is_binary(chat_id) do
    table = table_name(pid)

    # Guard against the ETS table not existing (e.g. Session GenServer is between
    # crash and restart). Returns [] rather than raising :badarg.
    try do
      case :ets.lookup(table, chat_id) do
        [{^chat_id, history}] -> history
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

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.get(opts, :name, __MODULE__)
    table = :"#{name}.Sessions"
    # :protected allows concurrent reads from any process (fast path for get_history)
    # while restricting writes to the owning GenServer (ordering guarantee).
    :ets.new(table, [:named_table, :protected, :set, read_concurrency: true])

    delta_store = Keyword.get(opts, :delta_store, nil)
    rehydrate_from_store(table, delta_store)


    Logger.info("[Kyber.Session] started (table: #{table})")
    {:ok, %{table: table, delta_store: delta_store}}
  end

  @impl true
  def handle_call({:add_message, chat_id, delta}, _from, %{table: table} = state) do
    history =
      case :ets.lookup(table, chat_id) do
        [{^chat_id, existing}] -> existing
        [] -> []
      end

    :ets.insert(table, {chat_id, history ++ [delta]})
    {:reply, :ok, state}
  end

  def handle_call({:clear, chat_id}, _from, %{table: table} = state) do
    :ets.delete(table, chat_id)
    {:reply, :ok, state}
  end

  def handle_call(:get_table, _from, %{table: table} = state) do
    {:reply, table, state}
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

        :ets.insert(table, {chat_id, sorted})
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
