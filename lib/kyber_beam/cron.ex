defmodule Kyber.Cron do
  @moduledoc """
  Scheduling system for heartbeats, reminders, and recurring tasks.

  Supports three schedule formats:
  - `{:every, ms}` — repeat every N milliseconds
  - `{:cron, "0 9 * * MON"}` — basic cron expression (min hour dom month dow)
  - `{:at, datetime}` — one-shot at a specific DateTime

  When a job fires, it emits a `"cron.fired"` delta with origin `{:cron, name}`.
  The reducer can pattern-match on these to trigger further effects.

  ## Cron expression support
  Fields: minute hour day-of-month month day-of-week
  Supported: `*`, exact values, `*/n` step syntax, comma-separated lists.
  Day-of-week accepts: 0-6 (0=Sun) or SUN/MON/TUE/WED/THU/FRI/SAT.
  """

  use GenServer
  require Logger

  @check_interval_ms 1_000  # check every second for due jobs

  @type schedule ::
    {:every, pos_integer()}
    | {:cron, String.t()}
    | {:at, DateTime.t()}

  @type callback :: (map() -> any()) | nil

  # ── Public API ──────────────────────────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Add a recurring or one-shot job."
  @spec add_job(GenServer.server(), String.t(), schedule(), callback()) :: :ok
  def add_job(server \\ __MODULE__, name, schedule, callback \\ nil) do
    GenServer.call(server, {:add_job, name, schedule, callback})
  end

  @doc "Remove a job by name."
  @spec remove_job(GenServer.server(), String.t()) :: :ok | {:error, :not_found}
  def remove_job(server \\ __MODULE__, name) do
    GenServer.call(server, {:remove_job, name})
  end

  @doc "List all scheduled jobs with their next run time."
  @spec list_jobs(GenServer.server()) :: [map()]
  def list_jobs(server \\ __MODULE__) do
    GenServer.call(server, :list_jobs)
  end

  @doc "Add a one-shot reminder that emits a delta at the given datetime."
  @spec add_reminder(GenServer.server(), String.t(), DateTime.t()) :: :ok
  def add_reminder(server \\ __MODULE__, message, datetime) do
    name = "reminder:#{:crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)}"
    schedule = {:at, datetime}

    callback = fn _job ->
      Logger.info("[Kyber.Cron] reminder fired: #{message}")
    end

    add_job(server, name, schedule, callback)
  end

  @doc "Get the core pid this cron instance emits into."
  @spec get_core(GenServer.server()) :: GenServer.server() | nil
  def get_core(server \\ __MODULE__) do
    GenServer.call(server, :get_core)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    core = Keyword.get(opts, :core, nil)
    check_interval = Keyword.get(opts, :check_interval, @check_interval_ms)

    state = %{
      core: core,
      jobs: %{},
      check_interval: check_interval
    }

    # Add default heartbeat job if configured
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, nil)
    state =
      if heartbeat_interval do
        add_job_to_state(state, "heartbeat", {:every, heartbeat_interval}, nil)
      else
        state
      end

    schedule_check(check_interval)
    Logger.info("[Kyber.Cron] started")
    {:ok, state}
  end

  @impl true
  def handle_call({:add_job, name, schedule, callback}, _from, state) do
    new_state = add_job_to_state(state, name, schedule, callback)
    {:reply, :ok, new_state}
  end

  def handle_call({:remove_job, name}, _from, state) do
    case Map.get(state.jobs, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _ ->
        new_jobs = Map.delete(state.jobs, name)
        {:reply, :ok, %{state | jobs: new_jobs}}
    end
  end

  def handle_call(:list_jobs, _from, state) do
    jobs =
      state.jobs
      |> Enum.map(fn {name, job} ->
        %{
          name: name,
          schedule: job.schedule,
          next_run: job.next_run,
          fired_count: job.fired_count
        }
      end)

    {:reply, jobs, state}
  end

  def handle_call(:get_core, _from, state) do
    {:reply, state.core, state}
  end

  @impl true
  def handle_info(:check_jobs, state) do
    now = DateTime.utc_now()
    {new_jobs, fired} = check_and_fire(state.jobs, now)

    # Emit deltas for fired jobs
    if state.core && fired != [] do
      Enum.each(fired, fn job ->
        emit_cron_delta(state.core, job)
      end)
    end

    # Run callbacks
    Enum.each(fired, fn job ->
      if job.callback do
        try do
          job.callback.(job)
        rescue
          e -> Logger.error("[Kyber.Cron] callback error for #{job.name}: #{inspect(e)}")
        end
      end
    end)

    schedule_check(state.check_interval)
    {:noreply, %{state | jobs: new_jobs}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  defp add_job_to_state(state, name, schedule, callback) do
    next_run = compute_next_run(schedule, DateTime.utc_now())

    job = %{
      name: name,
      schedule: schedule,
      callback: callback,
      next_run: next_run,
      fired_count: 0
    }

    %{state | jobs: Map.put(state.jobs, name, job)}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_jobs, interval)
  end

  defp check_and_fire(jobs, now) do
    Enum.reduce(jobs, {%{}, []}, fn {name, job}, {new_jobs, fired} ->
      if DateTime.compare(job.next_run, now) != :gt do
        # Job is due
        updated_job = %{job | fired_count: job.fired_count + 1}

        case job.schedule do
          {:at, _} ->
            # One-shot: remove after firing
            {new_jobs, [updated_job | fired]}

          schedule ->
            # Recurring: compute next run
            next = compute_next_run(schedule, now)
            updated_job = %{updated_job | next_run: next}
            {Map.put(new_jobs, name, updated_job), [updated_job | fired]}
        end
      else
        {Map.put(new_jobs, name, job), fired}
      end
    end)
  end

  defp emit_cron_delta(core, job) do
    delta = Kyber.Delta.new(
      "cron.fired",
      %{
        "job_name" => job.name,
        "schedule" => schedule_to_string(job.schedule),
        "fired_count" => job.fired_count
      },
      {:cron, job.name}
    )

    try do
      Kyber.Core.emit(core, delta)
    rescue
      e -> Logger.error("[Kyber.Cron] failed to emit delta for #{job.name}: #{inspect(e)}")
    end
  end

  defp schedule_to_string({:every, ms}), do: "every:#{ms}"
  defp schedule_to_string({:cron, expr}), do: "cron:#{expr}"
  defp schedule_to_string({:at, dt}), do: "at:#{DateTime.to_iso8601(dt)}"

  @doc false
  def compute_next_run({:every, ms}, from) when is_integer(ms) and ms > 0 do
    DateTime.add(from, ms, :millisecond)
  end

  def compute_next_run({:at, dt}, _from) do
    dt
  end

  def compute_next_run({:cron, expr}, from) do
    compute_next_cron(expr, from)
  end

  @doc false
  def compute_next_cron(expr, from) do
    case parse_cron(expr) do
      {:ok, fields} -> next_cron_time(fields, from)
      {:error, _} -> DateTime.add(from, 60, :second)
    end
  end

  @doc false
  def parse_cron(expr) do
    parts = String.split(expr)

    if length(parts) != 5 do
      {:error, :invalid_cron}
    else
      [min_str, hour_str, dom_str, month_str, dow_str] = parts

      with {:ok, minutes} <- parse_field(min_str, 0, 59),
           {:ok, hours}   <- parse_field(hour_str, 0, 23),
           {:ok, doms}    <- parse_field(dom_str, 1, 31),
           {:ok, months}  <- parse_field(month_str, 1, 12),
           {:ok, dows}    <- parse_dow_field(dow_str) do
        {:ok, %{minutes: minutes, hours: hours, doms: doms, months: months, dows: dows}}
      end
    end
  end

  defp parse_field("*", min, max), do: {:ok, Enum.to_list(min..max)}

  defp parse_field("*/" <> step_str, min, max) do
    case Integer.parse(step_str) do
      {step, ""} when step > 0 ->
        values = Enum.filter(min..max, fn n -> rem(n - min, step) == 0 end)
        {:ok, values}

      _ ->
        {:error, :invalid_step}
    end
  end

  defp parse_field(field, min, max) do
    parts = String.split(field, ",")

    results =
      Enum.reduce_while(parts, [], fn part, acc ->
        case Integer.parse(part) do
          {n, ""} when n >= min and n <= max -> {:cont, [n | acc]}
          _ -> {:halt, {:error, :invalid_value}}
        end
      end)

    case results do
      {:error, _} = err -> err
      values -> {:ok, Enum.sort(values)}
    end
  end

  @dow_names %{
    "SUN" => 0, "MON" => 1, "TUE" => 2, "WED" => 3,
    "THU" => 4, "FRI" => 5, "SAT" => 6
  }

  defp parse_dow_field("*"), do: {:ok, Enum.to_list(0..6)}

  defp parse_dow_field(field) do
    parts = String.split(field, ",")

    results =
      Enum.reduce_while(parts, [], fn part, acc ->
        cond do
          Map.has_key?(@dow_names, String.upcase(part)) ->
            {:cont, [Map.get(@dow_names, String.upcase(part)) | acc]}

          match?({n, ""} when n >= 0 and n <= 6, Integer.parse(part)) ->
            {n, ""} = Integer.parse(part)
            {:cont, [n | acc]}

          true ->
            {:halt, {:error, :invalid_dow}}
        end
      end)

    case results do
      {:error, _} = err -> err
      values -> {:ok, Enum.sort(values)}
    end
  end

  # Find the next DateTime after `from` that matches the cron fields.
  # We advance minute-by-minute up to 366 days to find a match.
  defp next_cron_time(fields, from) do
    # Start from the next minute
    start = from |> DateTime.add(60, :second) |> truncate_to_minute()
    find_match(fields, start, 0)
  end

  defp find_match(_fields, dt, limit) when limit > 525_601 do
    # More than a year of minutes — give up
    DateTime.add(dt, 60, :second)
  end

  defp find_match(fields, dt, limit) do
    dow = day_of_week(dt)  # 0=Sun ... 6=Sat

    if dt.minute in fields.minutes and
       dt.hour in fields.hours and
       dt.day in fields.doms and
       dt.month in fields.months and
       dow in fields.dows do
      dt
    else
      find_match(fields, DateTime.add(dt, 60, :second), limit + 1)
    end
  end

  defp truncate_to_minute(dt) do
    %{dt | second: 0, microsecond: {0, 0}}
  end

  # Returns 0-6 (0=Sunday) matching standard cron dow
  defp day_of_week(dt) do
    # Date.day_of_week returns 1=Mon...7=Sun in Elixir
    # We need 0=Sun...6=Sat
    case Date.day_of_week(DateTime.to_date(dt)) do
      7 -> 0  # Sunday
      n -> n  # Mon=1, Tue=2, ..., Sat=6
    end
  end
end
