defmodule Kyber.Distribution do
  @moduledoc """
  Multi-node BEAM distribution for Kyber.

  Allows Kyber instances on different machines to connect and share deltas.
  When a delta is emitted locally it is broadcast to all connected nodes.
  When a delta arrives from a remote node it is applied locally (with
  deduplication to prevent loops).

  ## Node connection

      Kyber.Distribution.connect(:"kyber@192.168.1.10")
      Kyber.Distribution.nodes()
      Kyber.Distribution.disconnect(:"kyber@192.168.1.10")

  ## Delta replication

  The Distribution GenServer subscribes to the local `Kyber.Delta.Store`.
  On each new delta:
  1. A `source_node` field is injected into the payload (if absent).
  2. The delta is sent via `:erpc.cast` to every connected remote node.

  On the remote side, `receive_remote_delta/1` (public, called by `:erpc`)
  deduplicates and appends to the local store.

  ## Reconnect sync

  `:net_kernel.monitor_nodes/1` is used to detect `:nodeup`/`:nodedown` events.
  On `:nodeup` for a known node, missed deltas are queried from the remote
  store (using the last-seen timestamp) and replayed locally.

  Sync runs in a supervised Task so the GenServer stays responsive during
  potentially long remote calls.

  ## Deduplication

  `seen_delta_ids` is a bounded cache of `{MapSet, :queue}`. When the set
  exceeds `@max_seen_ids` entries the oldest entry is evicted, keeping memory
  usage capped even during long-running sessions.
  """

  use GenServer
  require Logger

  @type node_name :: atom()

  # Max entries in the dedup cache before evicting oldest.
  @max_seen_ids 50_000

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the Distribution GenServer."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Connect to a remote Kyber node. Returns :ok or {:error, reason}."
  @spec connect(GenServer.server(), node_name()) :: :ok | {:error, :unreachable}
  def connect(server \\ __MODULE__, node_name) when is_atom(node_name) do
    GenServer.call(server, {:connect, node_name})
  end

  @doc "Disconnect from a remote node."
  @spec disconnect(GenServer.server(), node_name()) :: :ok
  def disconnect(server \\ __MODULE__, node_name) when is_atom(node_name) do
    GenServer.call(server, {:disconnect, node_name})
  end

  @doc "List currently connected Kyber nodes."
  @spec nodes(GenServer.server()) :: [node_name()]
  def nodes(server \\ __MODULE__) do
    GenServer.call(server, :list_nodes)
  end

  @doc "Broadcast a delta to all connected remote nodes (called internally)."
  @spec broadcast_delta(GenServer.server(), Kyber.Delta.t()) :: :ok
  def broadcast_delta(server \\ __MODULE__, %Kyber.Delta{} = delta) do
    GenServer.cast(server, {:broadcast_delta, delta})
  end

  @doc """
  Receive a delta from a remote node (called via `:erpc` on the receiving node).

  This is public because it must be callable from remote nodes via `:erpc.cast`.
  """
  @spec receive_remote_delta(Kyber.Delta.t()) :: :ok | :duplicate
  def receive_remote_delta(%Kyber.Delta{} = delta) do
    GenServer.call(__MODULE__, {:receive_remote_delta, delta})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    :net_kernel.monitor_nodes(true)

    # Accept explicit store name or default to the Core-scoped store name
    store = Keyword.get(opts, :store, :"#{Kyber.Core}.Store")
    auto_nodes = Keyword.get(opts, :auto_nodes, [])

    # Supervised task pool for async operations (sync, etc.)
    {:ok, task_sup} = Task.Supervisor.start_link()

    state = %{
      nodes: MapSet.new(),
      last_seen_ts: %{},
      store: store,
      # Bounded dedup cache: {MapSet, :queue} — capped at @max_seen_ids
      seen_delta_ids: {MapSet.new(), :queue.new()},
      unsubscribe_fn: nil,
      auto_nodes: auto_nodes,
      task_sup: task_sup
    }

    Logger.info("[Kyber.Distribution] started, node=#{node()}")
    # Use handle_continue to subscribe after init returns — guarantees the
    # store process is fully started before we call subscribe on it.
    {:ok, state, {:continue, :subscribe}}
  end

  @impl true
  def handle_continue(:subscribe, state) do
    self_pid = self()

    unsubscribe_fn =
      try do
        Kyber.Delta.Store.subscribe(state.store, fn delta ->
          broadcast_delta(self_pid, delta)
        end)
      rescue
        e ->
          Logger.warning("[Kyber.Distribution] could not subscribe to store #{inspect(state.store)}: #{inspect(e)}")
          fn -> :ok end
      end

    # Auto-connect to configured nodes
    new_state =
      Enum.reduce(state.auto_nodes, %{state | unsubscribe_fn: unsubscribe_fn}, fn node_name, acc ->
        {_result, updated} = do_connect(node_name, acc)
        updated
      end)

    {:noreply, new_state}
  end

  @impl true
  def handle_call({:connect, node_name}, _from, state) do
    {result, new_state} = do_connect(node_name, state)
    {:reply, result, new_state}
  end

  @impl true
  def handle_call({:disconnect, node_name}, _from, state) do
    nodes = MapSet.delete(state.nodes, node_name)
    ts = System.system_time(:millisecond)
    last_seen = Map.put(state.last_seen_ts, node_name, ts)
    Logger.info("[Kyber.Distribution] disconnected from #{node_name}")
    {:reply, :ok, %{state | nodes: nodes, last_seen_ts: last_seen}}
  end

  @impl true
  def handle_call(:list_nodes, _from, state) do
    {:reply, MapSet.to_list(state.nodes), state}
  end

  @impl true
  def handle_call({:receive_remote_delta, delta}, _from, state) do
    if dedup_seen?(state.seen_delta_ids, delta.id) do
      {:reply, :duplicate, state}
    else
      seen = dedup_add(state.seen_delta_ids, delta.id)
      :ok = Kyber.Delta.Store.append(state.store, delta)
      Logger.debug("[Kyber.Distribution] received remote delta #{delta.id} kind=#{delta.kind}")
      {:reply, :ok, %{state | seen_delta_ids: seen}}
    end
  end

  @impl true
  def handle_cast({:broadcast_delta, delta}, state) do
    # Don't re-broadcast deltas that originated elsewhere (loop prevention)
    source = Map.get(delta.payload, "source_node")

    if source == nil or source == to_string(node()) do
      # Tag with source node
      tagged_delta = %{
        delta
        | payload: Map.put(delta.payload, "source_node", to_string(node()))
      }

      # Mark as seen so we don't re-apply our own broadcast
      seen = dedup_add(state.seen_delta_ids, tagged_delta.id)
      new_state = %{state | seen_delta_ids: seen}

      # Send to all connected remote nodes
      Enum.each(MapSet.to_list(state.nodes), fn remote_node ->
        :erpc.cast(remote_node, __MODULE__, :receive_remote_delta, [tagged_delta])
      end)

      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:sync_results, remote_node, deltas}, state) do
    # Apply deltas received from an async sync task, deduplicating as we go.
    {new_seen, count} =
      Enum.reduce(deltas, {state.seen_delta_ids, 0}, fn delta, {seen, n} ->
        if dedup_seen?(seen, delta.id) do
          {seen, n}
        else
          :ok = Kyber.Delta.Store.append(state.store, delta)
          {dedup_add(seen, delta.id), n + 1}
        end
      end)

    Logger.info("[Kyber.Distribution] synced #{count} deltas from #{remote_node}")
    {:noreply, %{state | seen_delta_ids: new_seen}}
  end

  @impl true
  def handle_info({:nodeup, node_name}, state) do
    Logger.info("[Kyber.Distribution] :nodeup #{node_name}")

    # If this is a known node, kick off an async sync so we don't block.
    new_state =
      if MapSet.member?(state.nodes, node_name) do
        since = Map.get(state.last_seen_ts, node_name, 0)
        spawn_sync_task(state.task_sup, self(), node_name, since)
        state
      else
        state
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_info({:nodedown, node_name}, state) do
    Logger.info("[Kyber.Distribution] :nodedown #{node_name}")
    ts = System.system_time(:millisecond)
    last_seen = Map.put(state.last_seen_ts, node_name, ts)
    {:noreply, %{state | last_seen_ts: last_seen}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp do_connect(node_name, state) do
    if MapSet.member?(state.nodes, node_name) do
      {:ok, state}
    else
      case :net_adm.ping(node_name) do
        :pong ->
          nodes = MapSet.put(state.nodes, node_name)
          since = Map.get(state.last_seen_ts, node_name, 0)
          spawn_sync_task(state.task_sup, self(), node_name, since)
          Logger.info("[Kyber.Distribution] connected to #{node_name}")
          {:ok, %{state | nodes: nodes}}

        :pang ->
          Logger.warning("[Kyber.Distribution] unreachable: #{node_name}")
          {{:error, :unreachable}, state}
      end
    end
  end

  # Spawn an async Task to fetch missed deltas from a remote node.
  # Results are delivered back via GenServer.cast so the GenServer stays
  # responsive during the (potentially slow) remote :erpc.call.
  defp spawn_sync_task(task_sup, server, remote_node, since_ts) do
    Task.Supervisor.start_child(task_sup, fn ->
      Logger.info("[Kyber.Distribution] syncing from #{remote_node} since #{since_ts}")

      try do
        remote_deltas =
          :erpc.call(remote_node, Kyber.Delta.Store, :query, [[since: since_ts]], 5_000)

        GenServer.cast(server, {:sync_results, remote_node, remote_deltas})
        Logger.info("[Kyber.Distribution] sync task complete for #{remote_node}, #{length(remote_deltas)} deltas queued")
      rescue
        e ->
          Logger.warning(
            "[Kyber.Distribution] sync failed for #{remote_node}: #{inspect(e)}"
          )
      end
    end)
  end

  # ── Bounded dedup cache helpers ───────────────────────────────────────────

  @doc false
  def dedup_seen?({set, _queue}, id), do: MapSet.member?(set, id)

  @doc false
  def dedup_add({set, queue}, id) do
    set = MapSet.put(set, id)
    queue = :queue.in(id, queue)

    if MapSet.size(set) > @max_seen_ids do
      {{:value, oldest}, queue} = :queue.out(queue)
      {MapSet.delete(set, oldest), queue}
    else
      {set, queue}
    end
  end

  @doc false
  def dedup_size({set, _queue}), do: MapSet.size(set)
end
