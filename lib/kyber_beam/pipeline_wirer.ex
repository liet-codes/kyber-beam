defmodule Kyber.Core.PipelineWirer do
  @moduledoc """
  GenServer that wires the Delta.Store subscription to the reducer pipeline.

  Started as the **last child** in `Kyber.Core`'s supervision tree. Because
  supervisors start children in order, when `init/1` runs here, all prior
  siblings (TaskSupervisor, Delta.Store, State, Executor, PluginManager) are
  guaranteed to be started and registered — eliminating the need for any
  `Process.sleep` hacks.

  ## Serialized reducer invocations

  Delta.Store broadcasts deltas to subscribers via Tasks, which means rapid
  deltas could invoke the reducer concurrently. To prevent this, the
  subscriber callback sends a cast to *this* GenServer, which processes
  deltas sequentially through its mailbox. This guarantees:
  1. Reducer invocations are strictly ordered (FIFO)
  2. Effects from one delta complete before the next delta is processed
  3. No concurrent state mutations
  """

  use GenServer
  require Logger

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts)
  end

  @impl true
  def init(opts) do
    core_name = Keyword.fetch!(opts, :core_name)
    store = Keyword.fetch!(opts, :store)
    state_server = Keyword.fetch!(opts, :state)
    executor = Keyword.fetch!(opts, :executor)

    # The subscriber callback only sends a cast to this GenServer,
    # ensuring deltas are processed sequentially through the mailbox.
    wirer_pid = self()

    unsubscribe_fn =
      Kyber.Delta.Store.subscribe(store, fn delta ->
        GenServer.cast(wirer_pid, {:process_delta, delta})
      end)

    Logger.info("[Kyber.Core] pipeline wired for #{inspect(core_name)}")

    {:ok,
     %{
       unsubscribe_fn: unsubscribe_fn,
       core_name: core_name,
       state_server: state_server,
       executor: executor
     }}
  end

  @impl true
  def handle_cast({:process_delta, delta}, state) do
    Logger.debug("[PipelineWirer] processing delta: #{delta.kind} (#{delta.id})")

    effects =
      try do
        Kyber.State.get_and_update(state.state_server, fn current_state ->
          {new_state, effects} = Kyber.Reducer.reduce(current_state, delta)
          {effects, new_state}
        end)
      rescue
        e ->
          Logger.error(
            "[Kyber.Core.PipelineWirer/#{inspect(state.core_name)}] reducer error: #{inspect(e)}\n" <>
              Exception.format_stacktrace(__STACKTRACE__)
          )

          []
      end

    if effects != [] do
      Logger.debug(
        "[PipelineWirer] effects from #{delta.kind}: #{inspect(Enum.map(effects, & &1.type))}"
      )
    end

    Enum.each(effects, fn effect ->
      try do
        case Kyber.Effect.Executor.execute(state.executor, effect) do
          {:ok, _ref} ->
            Logger.debug("[PipelineWirer] dispatched effect: #{effect.type}")

          {:error, reason} ->
            Logger.warning(
              "[Kyber.Core.PipelineWirer/#{inspect(state.core_name)}] effect dispatch failed: #{inspect(reason)}"
            )
        end
      rescue
        e ->
          Logger.error(
            "[Kyber.Core.PipelineWirer/#{inspect(state.core_name)}] effect dispatch error: #{inspect(e)}"
          )
      end
    end)

    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{unsubscribe_fn: unsubscribe_fn}) do
    try do
      unsubscribe_fn.()
    rescue
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok
end
