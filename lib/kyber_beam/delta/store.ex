defmodule Kyber.Delta.Store do
  @moduledoc """
  GenServer that persists Deltas to a JSONL file and supports:
  - `append/2` — write a delta to the log
  - `query/2` — read deltas with optional filters (since, kind, limit)
  - `subscribe/2` — register a callback for new deltas (returns unsubscribe fn)

  PubSub is handled via a Registry; each subscriber registers under the
  store's name. On append, all registered callbacks are called in their
  own Task so the store process is never blocked.
  """

  use GenServer
  require Logger

  @registry Kyber.Delta.Store.Registry

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start a Store backed by the given file path."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.get(opts, :path, default_path())
    GenServer.start_link(__MODULE__, %{path: path, name: name}, name: name)
  end

  @doc "Append a delta to the store. Broadcasts to all subscribers."
  @spec append(GenServer.server(), Kyber.Delta.t()) :: :ok
  def append(pid, %Kyber.Delta{} = delta) do
    GenServer.call(pid, {:append, delta})
  end

  @doc """
  Query deltas with optional filters:
  - `:since` — only deltas with `ts >= since` (milliseconds)
  - `:kind` — only deltas matching this kind string
  - `:limit` — maximum number of results (newest-first after filtering)
  """
  @spec query(GenServer.server(), keyword()) :: [Kyber.Delta.t()]
  def query(pid, filters \\ []) do
    GenServer.call(pid, {:query, filters})
  end

  @doc """
  Subscribe to new deltas. The `callback_fn` will be called with each new
  `%Kyber.Delta{}` as it's appended.

  Returns an unsubscribe function — call it to stop receiving events.
  """
  @spec subscribe(GenServer.server(), (Kyber.Delta.t() -> any())) :: (() -> :ok)
  def subscribe(pid, callback_fn) when is_function(callback_fn, 1) do
    GenServer.call(pid, {:subscribe, callback_fn})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(%{path: path, name: name}) do
    Process.flag(:trap_exit, true)
    deltas = load_from_disk(path)
    Logger.info("[Kyber.Delta.Store] started, loaded #{length(deltas)} deltas from #{path}")
    {:ok, %{path: path, deltas: deltas, name: name, subs: %{}}}
  end

  @impl true
  def handle_call({:append, delta}, _from, state) do
    :ok = write_line(state.path, delta)
    state = %{state | deltas: state.deltas ++ [delta]}
    broadcast(state, delta)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:query, filters}, _from, state) do
    results =
      state.deltas
      |> apply_since(Keyword.get(filters, :since))
      |> apply_kind(Keyword.get(filters, :kind))
      |> apply_limit(Keyword.get(filters, :limit))

    {:reply, results, state}
  end

  @impl true
  def handle_call({:subscribe, callback_fn}, _from, state) do
    sub_id = make_ref()
    subs = Map.put(state.subs, sub_id, callback_fn)
    store_name = state.name

    unsubscribe_fn = fn ->
      GenServer.call(store_name, {:unsubscribe, sub_id})
    end

    {:reply, unsubscribe_fn, %{state | subs: subs}}
  end

  @impl true
  def handle_call({:unsubscribe, sub_id}, _from, state) do
    subs = Map.delete(state.subs, sub_id)
    {:reply, :ok, %{state | subs: subs}}
  end

  @impl true
  def handle_info(msg, state) do
    Logger.warning("[Kyber.Delta.Store] unexpected message: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("[Kyber.Delta.Store] terminating: #{inspect(reason)}")
    :ok
  end

  # ── Private helpers ───────────────────────────────────────────────────────

  defp default_path do
    data_dir = System.get_env("KYBER_DATA_DIR", "priv/data")
    File.mkdir_p!(data_dir)
    Path.join(data_dir, "deltas.jsonl")
  end

  defp load_from_disk(path) do
    case File.read(path) do
      {:ok, contents} ->
        contents
        |> String.split("\n", trim: true)
        |> Enum.flat_map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> [Kyber.Delta.from_map(map)]
            {:error, reason} ->
              Logger.warning("[Kyber.Delta.Store] skipping bad line: #{inspect(reason)}")
              []
          end
        end)

      {:error, :enoent} ->
        []

      {:error, reason} ->
        Logger.error("[Kyber.Delta.Store] failed to read #{path}: #{inspect(reason)}")
        []
    end
  end

  defp write_line(path, delta) do
    json = Jason.encode!(Kyber.Delta.to_map(delta))
    File.write!(path, json <> "\n", [:append])
    :ok
  end

  defp apply_since(deltas, nil), do: deltas
  defp apply_since(deltas, since), do: Enum.filter(deltas, &(&1.ts >= since))

  defp apply_kind(deltas, nil), do: deltas
  defp apply_kind(deltas, kind), do: Enum.filter(deltas, &(&1.kind == kind))

  defp apply_limit(deltas, nil), do: deltas
  defp apply_limit(deltas, limit), do: Enum.take(deltas, limit)

  defp broadcast(%{subs: subs}, delta) do
    Enum.each(subs, fn {_id, callback_fn} ->
      Task.start(fn -> callback_fn.(delta) end)
    end)
  end
end
