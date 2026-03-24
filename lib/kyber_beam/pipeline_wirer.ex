defmodule Kyber.Core.PipelineWirer do
  @moduledoc """
  GenServer that wires the Delta.Store subscription to the reducer pipeline.

  Started as the **last child** in `Kyber.Core`'s supervision tree. Because
  supervisors start children in order, when `init/1` runs here, all prior
  siblings (TaskSupervisor, Delta.Store, State, Executor, PluginManager) are
  guaranteed to be started and registered — eliminating the need for any
  `Process.sleep` hacks.

  Calling `Delta.Store.subscribe/2` from `init/1` is safe and synchronous:
  the subscription is registered before `init/1` returns `{:ok, state}`,
  which is before the supervisor considers startup complete.
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

    unsubscribe_fn =
      Kyber.Delta.Store.subscribe(store, fn delta ->
        Logger.debug("[PipelineWirer] processing delta: #{delta.kind} (#{delta.id})")

        effects =
          try do
            Kyber.State.get_and_update(state_server, fn current_state ->
              {new_state, effects} = Kyber.Reducer.reduce(current_state, delta)
              {effects, new_state}
            end)
          rescue
            e ->
              Logger.error(
                "[Kyber.Core.PipelineWirer/#{inspect(core_name)}] reducer error: #{inspect(e)}\n" <>
                  Exception.format_stacktrace(__STACKTRACE__)
              )

              []
          end

        if effects != [] do
          Logger.debug("[PipelineWirer] effects from #{delta.kind}: #{inspect(Enum.map(effects, & &1.type))}")
        end

        Enum.each(effects, fn effect ->
          try do
            case Kyber.Effect.Executor.execute(executor, effect) do
              {:ok, _ref} ->
                Logger.debug("[PipelineWirer] dispatched effect: #{effect.type}")

              {:error, reason} ->
                Logger.warning(
                  "[Kyber.Core.PipelineWirer/#{inspect(core_name)}] effect dispatch failed: #{inspect(reason)}"
                )
            end
          rescue
            e ->
              Logger.error(
                "[Kyber.Core.PipelineWirer/#{inspect(core_name)}] effect dispatch error: #{inspect(e)}"
              )
          end
        end)
      end)

    Logger.info("[Kyber.Core] pipeline wired for #{inspect(core_name)}")
    {:ok, %{unsubscribe_fn: unsubscribe_fn, core_name: core_name}}
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
