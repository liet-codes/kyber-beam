defmodule Kyber.SessionCleaner do
  @moduledoc """
  Periodic cleaner that sweeps stale sessions from `Kyber.Session`.

  Runs on a configurable interval (default 5 minutes) and removes sessions
  that have been inactive longer than the configured TTL.

  ## Options

    * `:session` — the Session server to clean (default `Kyber.Session`)
    * `:interval_ms` — sweep interval in milliseconds (default 5 minutes)
    * `:ttl_ms` — inactivity TTL in milliseconds (default 1 hour)
    * `:name` — GenServer registration name
  """

  use GenServer
  require Logger

  @default_interval_ms :timer.minutes(5)
  @default_ttl_ms :timer.hours(1)

  # ── Public API ────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Trigger an immediate sweep. Useful for testing."
  @spec sweep_now(GenServer.server()) :: [String.t()]
  def sweep_now(pid \\ __MODULE__) do
    GenServer.call(pid, :sweep_now)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    session = Keyword.get(opts, :session, Kyber.Session)
    interval_ms = Keyword.get(opts, :interval_ms, @default_interval_ms)
    ttl_ms = Keyword.get(opts, :ttl_ms, @default_ttl_ms)

    state = %{
      session: session,
      interval_ms: interval_ms,
      ttl_ms: ttl_ms
    }

    schedule_sweep(interval_ms)
    Logger.info("[Kyber.SessionCleaner] started (interval: #{interval_ms}ms, ttl: #{ttl_ms}ms)")
    {:ok, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    do_sweep(state)
    schedule_sweep(state.interval_ms)
    {:noreply, state}
  end

  @impl true
  def handle_call(:sweep_now, _from, state) do
    swept = do_sweep(state)
    {:reply, swept, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp do_sweep(%{session: session, ttl_ms: ttl_ms}) do
    Kyber.Session.sweep_stale(session, ttl_ms)
  rescue
    e ->
      Logger.error("[Kyber.SessionCleaner] sweep failed: #{inspect(e)}")
      []
  end

  defp schedule_sweep(interval_ms) do
    Process.send_after(self(), :sweep, interval_ms)
  end
end
