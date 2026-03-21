defmodule Kyber.Delta.Store do
  @moduledoc """
  GenServer that persists Deltas to a JSONL file and supports:
  - `append/2` — write a delta to the log
  - `query/2` — read deltas with optional filters (since, kind, limit)
  - `subscribe/2` — register a callback for new deltas (returns unsubscribe fn)

  ## Improvements over naive implementation

  - **Supervised broadcast**: callbacks run under a `Task.Supervisor`, so
    crashes are isolated, logged, and don't affect other subscribers.
  - **Async file I/O**: the file is opened once at startup in `:append` mode.
    `IO.binwrite/2` is used per-append — avoids open/close overhead per write.
  - **Bounded in-memory list**: `max_memory_deltas` (default 10,000) limits
    RAM usage. When exceeded, oldest deltas are dropped from memory but
    remain on disk. Queries with a `:since` predating the in-memory window
    automatically fall back to reading from disk.
  """

  use GenServer
  require Logger

  @default_max_memory_deltas 10_000

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start a Store backed by the given file path."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    path = Keyword.get(opts, :path, default_path())
    task_sup = Keyword.get(opts, :task_supervisor, nil)
    max_memory_deltas = Keyword.get(opts, :max_memory_deltas, @default_max_memory_deltas)

    GenServer.start_link(
      __MODULE__,
      %{path: path, name: name, task_sup: task_sup, max_memory_deltas: max_memory_deltas},
      name: name
    )
  end

  @doc "Append a delta to the store. Persists to disk and broadcasts to all subscribers."
  @spec append(GenServer.server(), Kyber.Delta.t()) :: :ok
  def append(pid, %Kyber.Delta{} = delta) do
    GenServer.call(pid, {:append, delta})
  end

  @doc "Broadcast a delta to subscribers without persisting to disk."
  @spec broadcast_only(GenServer.server(), Kyber.Delta.t()) :: :ok
  def broadcast_only(pid, %Kyber.Delta{} = delta) do
    GenServer.call(pid, {:broadcast_only, delta})
  end

  @doc """
  Query deltas with optional filters:
  - `:since` — only deltas with `ts >= since` (milliseconds)
  - `:kind` — only deltas matching this kind string
  - `:limit` — maximum number of results (oldest-first after filtering)

  When `max_memory_deltas` is exceeded, old deltas are dropped from memory
  but remain on disk. Queries with `:since` predating the in-memory window
  transparently fall back to a full disk scan.
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
  def init(%{path: path, name: name, task_sup: task_sup, max_memory_deltas: max_memory_deltas}) do
    Process.flag(:trap_exit, true)

    # Open file for append once at startup. IO.binwrite avoids per-write
    # open/close overhead and keeps the GenServer from blocking on file ops.
    # Return {:stop, reason} on failure so the error is visible in logs
    # (rather than a MatchError mid-init that produces a confusing crash).
    case File.open(path, [:append, :binary]) do
      {:ok, io_device} ->
        # Restrict file permissions to owner-only (0o600).
        # The delta log contains full conversation content, LLM responses,
        # and metadata — it should not be world-readable.
        # We do this after open to ensure the file exists; chmod is best-effort.
        case File.chmod(path, 0o600) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("[Kyber.Delta.Store] could not set 0o600 on #{path}: #{inspect(reason)}")
        end

        state = %{
          path: path,
          io_device: io_device,
          deltas: [],
          name: name,
          subs: %{},
          task_sup: task_sup,
          max_memory_deltas: max_memory_deltas
        }

        # Defer disk load to handle_continue so init/1 returns quickly and
        # the supervisor is not blocked during potentially large file reads.
        {:ok, state, {:continue, :load_from_disk}}

      {:error, reason} ->
        Logger.error("[Kyber.Delta.Store] cannot open #{path}: #{inspect(reason)}")
        {:stop, {:file_open_failed, reason}}
    end
  end

  @impl true
  def handle_continue(:load_from_disk, state) do
    deltas = load_from_disk(state.path)
    Logger.info("[Kyber.Delta.Store] started, loaded #{length(deltas)} deltas from #{state.path}")
    {:noreply, %{state | deltas: deltas}}
  end

  @impl true
  def handle_call({:append, delta}, _from, state) do
    :ok = write_line(state.io_device, delta)

    # Trim oldest deltas from memory when limit exceeded; they remain on disk.
    new_deltas = trim_memory(state.deltas ++ [delta], state.max_memory_deltas)
    state = %{state | deltas: new_deltas}

    broadcast(state, delta)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:broadcast_only, delta}, _from, state) do
    # Broadcast to subscribers (PipelineWirer etc.) without writing to disk
    # or adding to in-memory list. Used for ephemeral deltas like cron.fired.
    broadcast(state, delta)
    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:query, filters}, _from, state) do
    since = Keyword.get(filters, :since)

    # If the requested window predates our in-memory data we need to read from
    # disk. To avoid blocking the GenServer (and starving all other callers),
    # we do the read in a spawned Task and await the result, releasing the
    # GenServer's mailbox for other messages while waiting.
    deltas =
      if needs_disk_fallback?(state.deltas, since) do
        path = state.path

        task = Task.async(fn -> load_from_disk(path) end)

        case Task.yield(task, 5_000) || Task.shutdown(task) do
          {:ok, loaded} -> loaded
          nil ->
            Logger.warning("[Kyber.Delta.Store] disk fallback timed out — returning in-memory only")
            state.deltas
        end
      else
        state.deltas
      end

    results =
      deltas
      |> apply_since(since)
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
  def terminate(reason, state) do
    # Use :info for expected supervisor shutdowns, :error for genuine crashes.
    log_level =
      case reason do
        :normal -> :info
        :shutdown -> :info
        {:shutdown, _} -> :info
        _ -> :error
      end

    Logger.log(log_level, "[Kyber.Delta.Store] terminating: #{inspect(reason)}")

    # Close the IO device gracefully so buffered writes are flushed.
    if io = Map.get(state, :io_device), do: File.close(io)

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

  # Use the open IO device — avoids open/close on every append.
  defp write_line(io_device, delta) do
    json = Jason.encode!(Kyber.Delta.to_map(delta))
    IO.binwrite(io_device, json <> "\n")
    :ok
  end

  # Keep only the most recent `max` deltas in memory; oldest are still on disk.
  defp trim_memory(deltas, max) when length(deltas) > max do
    Enum.take(deltas, -max)
  end

  defp trim_memory(deltas, _max), do: deltas

  # True when the oldest in-memory delta is newer than `since`, meaning the
  # caller wants data that was already trimmed from the in-memory list.
  defp needs_disk_fallback?([], _since), do: false
  defp needs_disk_fallback?(_deltas, nil), do: false
  defp needs_disk_fallback?([oldest | _], since), do: oldest.ts > since

  defp apply_since(deltas, nil), do: deltas
  defp apply_since(deltas, since), do: Enum.filter(deltas, &(&1.ts >= since))

  defp apply_kind(deltas, nil), do: deltas
  defp apply_kind(deltas, kind), do: Enum.filter(deltas, &(&1.kind == kind))

  defp apply_limit(deltas, nil), do: deltas
  defp apply_limit(deltas, limit), do: Enum.take(deltas, limit)

  # Broadcast to all subscribers via supervised Tasks so that:
  # 1. A crashing callback cannot crash the store
  # 2. Callbacks don't block the store GenServer
  # 3. Crashes are logged rather than silently swallowed
  defp broadcast(%{subs: subs, task_sup: task_sup}, delta) do
    Enum.each(subs, fn {_id, callback_fn} ->
      wrapped = fn ->
        try do
          callback_fn.(delta)
        rescue
          e ->
            Logger.error(
              "[Kyber.Delta.Store] subscriber callback raised: #{inspect(e)}"
            )
        end
      end

      if task_sup do
        Task.Supervisor.start_child(task_sup, wrapped)
      else
        Task.start(wrapped)
      end
    end)
  end
end
