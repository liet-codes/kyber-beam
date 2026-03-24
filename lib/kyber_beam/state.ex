defmodule Kyber.State do
  @moduledoc """
  Kyber application state — the running snapshot of what the system knows.

  Wraps a `%Kyber.State{}` struct in an Agent for safe concurrent access.

  Fields:
  - `sessions` — map of session_id → session data
  - `plugins` — list of loaded plugin names
  - `errors` — list of error maps (recent errors, newest last)
  """

  @typedoc "A Kyber.State struct"
  @type t :: %__MODULE__{
          sessions: %{String.t() => map()},
          plugins: [String.t()],
          errors: [map()]
        }

  defstruct sessions: %{}, plugins: [], errors: []

  # ── Supervisor integration ────────────────────────────────────────────────

  @doc false
  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      type: :worker,
      restart: :permanent,
      shutdown: 5000
    }
  end

  # ── Agent API ─────────────────────────────────────────────────────────────

  @doc "Start the State agent with an empty initial state."
  @spec start_link(any()) :: Agent.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    Agent.start_link(fn -> %__MODULE__{} end, name: name)
  end

  @doc "Start an unnamed State agent (useful in tests)."
  @spec start(any()) :: Agent.on_start()
  def start(_opts \\ []) do
    Agent.start(fn -> %__MODULE__{} end)
  end

  @doc "Get the current state."
  @spec get(Agent.agent()) :: t()
  def get(pid \\ __MODULE__) do
    Agent.get(pid, & &1)
  end

  @doc """
  Update the state by applying a function `fun :: t() -> t()`.
  Returns the new state.
  """
  @spec update(Agent.agent(), (t() -> t())) :: :ok
  def update(pid \\ __MODULE__, fun) when is_function(fun, 1) do
    Agent.update(pid, fun)
  end

  @doc """
  Apply an update function and return the resulting state.
  """
  @spec get_and_update(Agent.agent(), (t() -> {any(), t()})) :: any()
  def get_and_update(pid \\ __MODULE__, fun) when is_function(fun, 1) do
    Agent.get_and_update(pid, fun)
  end

  @doc "Stop the State agent."
  @spec stop(Agent.agent()) :: :ok
  def stop(pid \\ __MODULE__) do
    Agent.stop(pid)
  end

  # ── Convenience helpers (pure, no Agent involved) ─────────────────────────

  @doc "Add a plugin name to the state (returns new struct)."
  @spec add_plugin(t(), String.t()) :: t()
  def add_plugin(%__MODULE__{} = state, plugin_name) do
    %{state | plugins: [plugin_name | state.plugins]}
  end

  # Keep at most this many errors in the in-memory list.
  # Prevents unbounded memory growth under sustained error conditions.
  @max_errors 100

  @doc "Prepend an error to the state (returns new struct). Keeps the most recent #{@max_errors}."
  @spec add_error(t(), map()) :: t()
  def add_error(%__MODULE__{} = state, error) when is_map(error) do
    trimmed = [error | state.errors] |> Enum.take(@max_errors)
    %{state | errors: trimmed}
  end

  @doc "Put a session entry (returns new struct)."
  @spec put_session(t(), String.t(), map()) :: t()
  def put_session(%__MODULE__{} = state, session_id, data) when is_binary(session_id) do
    %{state | sessions: Map.put(state.sessions, session_id, data)}
  end
end
