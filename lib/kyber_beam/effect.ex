defmodule Kyber.Effect.Executor do
  @moduledoc """
  GenServer that dispatches effects to registered handler functions.

  Handlers are registered by effect type (atom). When an effect is executed,
  the matching handler is called asynchronously via a Task so the Executor
  process is never blocked.

  ## Usage

      {:ok, pid} = Kyber.Effect.Executor.start_link()

      Kyber.Effect.Executor.register(pid, :llm_call, fn effect ->
        # do the LLM call
        {:ok, %{result: "..."}}
      end)

      {:ok, task_ref} = Kyber.Effect.Executor.execute(pid, %{type: :llm_call, payload: %{...}})
  """

  use GenServer
  require Logger

  # ── Public API ─────────────────────────────────────────────────────────────

  @doc "Start the Executor."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    task_sup = Keyword.get(opts, :task_supervisor, Kyber.Effect.TaskSupervisor)
    GenServer.start_link(__MODULE__, %{handlers: %{}, task_sup: task_sup}, name: name)
  end

  @doc "Register a handler function for a given effect type."
  @spec register(GenServer.server(), atom(), (map() -> any())) :: :ok
  def register(pid, effect_type, handler_fn)
      when is_atom(effect_type) and is_function(handler_fn, 1) do
    GenServer.call(pid, {:register, effect_type, handler_fn})
  end

  @doc """
  Execute an effect map asynchronously.

  Effects are plain maps with at minimum a `:type` key (atom). See
  `Kyber.Reducer` for the canonical effect format.

  Dispatches to the registered handler (if any) via a supervised Task.
  Returns `{:ok, task_ref}` immediately — does not wait for the handler.
  Returns `{:error, :no_handler}` if no handler is registered for the type.
  """
  @spec execute(GenServer.server(), map()) :: {:ok, reference()} | {:error, atom()}
  def execute(pid, effect) do
    GenServer.call(pid, {:execute, effect})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def handle_call({:register, effect_type, handler_fn}, _from, state) do
    handlers = Map.put(state.handlers, effect_type, handler_fn)
    {:reply, :ok, %{state | handlers: handlers}}
  end

  @impl true
  def handle_call({:execute, effect}, _from, state) do
    type = get_type(effect)

    case Map.fetch(state.handlers, type) do
      {:ok, handler_fn} ->
        task =
          Task.Supervisor.async_nolink(state.task_sup, fn ->
            try do
              handler_fn.(effect)
            rescue
              e ->
                Logger.error("[Kyber.Effect.Executor] handler #{type} raised: #{inspect(e)}")
                {:error, {:handler_raised, e}}
            end
          end)

        {:reply, {:ok, task.ref}, state}

      :error ->
        Logger.warning("[Kyber.Effect.Executor] no handler for effect type: #{inspect(type)}")
        {:reply, {:error, :no_handler}, state}
    end
  end

  @impl true
  def handle_info({ref, _result}, state) when is_reference(ref) do
    # Task completed — demonitor silently
    Process.demonitor(ref, [:flush])
    {:noreply, state}
  end

  def handle_info({:DOWN, _ref, :process, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:DOWN, _ref, :process, _pid, reason}, state) do
    Logger.warning("[Kyber.Effect.Executor] task died: #{inspect(reason)}")
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.warning("[Kyber.Effect.Executor] unexpected: #{inspect(msg)}")
    {:noreply, state}
  end

  @impl true
  def terminate(reason, _state) do
    Logger.info("[Kyber.Effect.Executor] terminating: #{inspect(reason)}")
    :ok
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp get_type(%{type: t}) when is_atom(t), do: t

  # String.to_existing_atom/1 would crash with ArgumentError for unknown atoms,
  # making this a DoS vector. We use a safe conversion instead: attempt to
  # match known types, or fall back gracefully to :unknown.
  defp get_type(%{"type" => t}) when is_binary(t), do: safe_to_atom(t)
  defp get_type(_), do: :unknown

  @known_effect_types ~w(
    llm_call
    discord_message
    error_route
    plugin_loaded
    message_received
  )a

  defp safe_to_atom(t) when t in @known_effect_types, do: String.to_existing_atom(t)

  defp safe_to_atom(t) when is_binary(t) do
    # For a personal tool, String.to_atom is acceptable — atom table is bounded
    # by known inputs. Unknown strings return :unknown rather than crashing.
    try do
      String.to_existing_atom(t)
    rescue
      ArgumentError -> :unknown
    end
  end
end
