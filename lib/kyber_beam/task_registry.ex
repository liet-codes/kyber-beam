defmodule Kyber.TaskRegistry do
  @moduledoc """
  Registry mapping task names (strings) to executor functions.

  Each registered task is a function `(params :: map()) -> any()`.
  Tasks can be registered at runtime or defined as built-in defaults.

  ## Built-in tasks (for testing)

  - `"echo"` — returns `params` as-is
  - `"sleep"` — sleeps for `params["ms"]` then returns `:slept`
  - `"fail"` — raises an error

  ## Usage

      {:ok, pid} = Kyber.TaskRegistry.start_link()
      Kyber.TaskRegistry.register(pid, "my_task", fn params -> do_work(params) end)
      {:ok, fun} = Kyber.TaskRegistry.lookup(pid, "my_task")
  """

  use GenServer

  # ── Public API ─────────────────────────────────────────────────────────────

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc "Register a task function by name."
  @spec register(GenServer.server(), String.t(), (map() -> any())) :: :ok
  def register(pid, name, fun) when is_binary(name) and is_function(fun, 1) do
    GenServer.call(pid, {:register, name, fun})
  end

  @doc "Look up a task function by name."
  @spec lookup(GenServer.server(), String.t()) :: {:ok, (map() -> any())} | {:error, :not_found}
  def lookup(pid, name) when is_binary(name) do
    GenServer.call(pid, {:lookup, name})
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(_) do
    {:ok, builtin_tasks()}
  end

  @impl true
  def handle_call({:register, name, fun}, _from, tasks) do
    {:reply, :ok, Map.put(tasks, name, fun)}
  end

  def handle_call({:lookup, name}, _from, tasks) do
    case Map.fetch(tasks, name) do
      {:ok, fun} -> {:reply, {:ok, fun}, tasks}
      :error -> {:reply, {:error, :not_found}, tasks}
    end
  end

  # ── Built-in tasks ────────────────────────────────────────────────────────

  defp builtin_tasks do
    %{
      "echo" => fn params -> params end,
      "sleep" => fn params ->
        ms = Map.get(params, "ms", 100)
        Process.sleep(ms)
        :slept
      end,
      "fail" => fn _params -> raise "intentional task failure" end
    }
  end
end
