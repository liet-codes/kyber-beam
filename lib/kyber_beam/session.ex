defmodule Kyber.Session do
  @moduledoc """
  Conversation history management for Kyber.

  Sessions are keyed by `chat_id` (derived from a delta's origin) and store
  an ordered list of message deltas for that conversation.

  History is stored in ETS for fast concurrent reads. The GenServer serialises
  writes so there are no race conditions when appending messages.

  ## Usage

      {:ok, pid} = Kyber.Session.start_link()

      Kyber.Session.add_message(pid, "chat_1", delta)
      history = Kyber.Session.get_history(pid, "chat_1")
      Kyber.Session.clear(pid, "chat_1")
      sessions = Kyber.Session.list_sessions(pid)
  """

  use GenServer
  require Logger

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
    case :ets.lookup(table, chat_id) do
      [{^chat_id, history}] -> history
      [] -> []
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
    :ets.new(table, [:named_table, :public, :set, read_concurrency: true])
    Logger.info("[Kyber.Session] started (table: #{table})")
    {:ok, %{table: table}}
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

  # Get the ETS table name for a given pid/name.
  # Since table is named after the process name, we need to look it up.
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
