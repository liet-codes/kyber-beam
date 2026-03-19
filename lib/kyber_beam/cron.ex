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

  ## Missed job detection

  On each tick, jobs whose `next_run` is significantly in the past (more than
  5 seconds behind wall clock) are flagged with `"missed" => true` in their
  delta payload. This handles the case where the machine slept or the system
  clock jumped forward.

  ## Job persistence

  Jobs are persisted to a JSONL file (one JSON object per line). On startup,
  jobs are reloaded from the file. One-shot `{:at, dt}` jobs whose target
  time is in the past are fired immediately on reload (marked as missed).
  Recurring jobs have their `next_run` recalculated from the current time.

  Callbacks cannot be serialized and are cleared on reload, but the
  `cron.fired` delta is still emitted, allowing reducers to react normally.

  Configure via opts:
  - `persist_path: "/path/to/cron_jobs.jsonl"` — where to store jobs
    Defaults to `~/.kyber/cron_jobs.jsonl`. Pass `nil` to disable.
  """

  use GenServer
  require Logger

  @check_interval_ms 1_000  # check every second for due jobs
  # A job is "missed" if now is this many ms past its scheduled next_run
  @missed_threshold_ms 5_000

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

    GenServer.call(server, {:add_job, name, schedule, callback, %{"label" => message}})
  end

  @doc "Get the core pid this cron instance emits into."
  @spec get_core(GenServer.server()) :: GenServer.server() | nil
  def get_core(server \\ __MODULE__) do
    GenServer.call(server, :get_core)
  end

  @doc "Get the persist path for job storage."
  @spec persist_path(GenServer.server()) :: String.t() | nil
  def persist_path(server \\ __MODULE__) do
    GenServer.call(server, :persist_path)
  end

  # ── GenServer callbacks ─────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    core = Keyword.get(opts, :core, nil)
    check_interval = Keyword.get(opts, :check_interval, @check_interval_ms)

    default_persist = Path.expand("~/.kyber/cron_jobs.jsonl")
    persist = Keyword.get(opts, :persist_path, default_persist)

    if is_nil(persist) do
      Logger.warning("[Kyber.Cron] persist_path is nil — one-shot reminders will not survive restarts")
    end

    state = %{
      core: core,
      jobs: %{},
      check_interval: check_interval,
      persist_path: persist
    }

    # Reload persisted jobs (before adding heartbeat, so heartbeat isn't duplicated)
    state = load_persisted_jobs(state)

    # Add default heartbeat job if configured
    heartbeat_interval = Keyword.get(opts, :heartbeat_interval, nil)
    state =
      if heartbeat_interval && !Map.has_key?(state.jobs, "heartbeat") do
        add_job_to_state(state, "heartbeat", {:every, heartbeat_interval}, nil, %{})
      else
        state
      end

    schedule_check(check_interval)
    Logger.info("[Kyber.Cron] started (#{map_size(state.jobs)} jobs loaded)")
    {:ok, state}
  end

  @impl true
  def handle_call({:add_job, name, schedule, callback}, _from, state) do
    new_state = add_job_to_state(state, name, schedule, callback, %{})
    persist_jobs(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:add_job, name, schedule, callback, metadata}, _from, state) do
    new_state = add_job_to_state(state, name, schedule, callback, metadata)
    persist_jobs(new_state)
    {:reply, :ok, new_state}
  end

  def handle_call({:remove_job, name}, _from, state) do
    case Map.get(state.jobs, name) do
      nil ->
        {:reply, {:error, :not_found}, state}

      _ ->
        new_jobs = Map.delete(state.jobs, name)
        new_state = %{state | jobs: new_jobs}
        persist_jobs(new_state)
        {:reply, :ok, new_state}
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

  def handle_call(:persist_path, _from, state) do
    {:reply, state.persist_path, state}
  end

  @impl true
  def handle_info(:check_jobs, state) do
    now = DateTime.utc_now()
    {new_jobs, fired} = check_and_fire(state.jobs, now, state.check_interval)

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

    # Persist if any one-shot jobs fired (they get removed)
    one_shots_fired = Enum.any?(fired, fn job -> match?({:at, _}, job.schedule) end)
    new_state = %{state | jobs: new_jobs}
    if one_shots_fired, do: persist_jobs(new_state)

    schedule_check(state.check_interval)
    {:noreply, new_state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # ── Private ─────────────────────────────────────────────────────────────────

  defp add_job_to_state(state, name, schedule, callback, metadata) do
    next_run = compute_next_run(schedule, DateTime.utc_now())

    job = %{
      name: name,
      schedule: schedule,
      callback: callback,
      next_run: next_run,
      fired_count: 0,
      metadata: metadata || %{},
      missed: false
    }

    %{state | jobs: Map.put(state.jobs, name, job)}
  end

  defp schedule_check(interval) do
    Process.send_after(self(), :check_jobs, interval)
  end

  defp check_and_fire(jobs, now, _check_interval) do
    Enum.reduce(jobs, {%{}, []}, fn {name, job}, {new_jobs, fired} ->
      if DateTime.compare(job.next_run, now) != :gt do
        # Determine if this job was missed (late by more than threshold)
        late_ms = DateTime.diff(now, job.next_run, :millisecond)
        missed = late_ms > @missed_threshold_ms

        updated_job = %{job | fired_count: job.fired_count + 1, missed: missed}

        case job.schedule do
          {:at, _} ->
            # One-shot: remove after firing
            {new_jobs, [updated_job | fired]}

          schedule ->
            # Recurring: compute next run from now (not from next_run, to avoid drift cascade)
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
        "fired_count" => job.fired_count,
        "missed" => job.missed,
        "label" => Map.get(job.metadata, "label")
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

  # ── Persistence ──────────────────────────────────────────────────────────────

  # Persist all jobs (without callbacks) to JSONL file.
  defp persist_jobs(%{persist_path: nil}), do: :ok

  defp persist_jobs(%{persist_path: path, jobs: jobs}) do
    lines =
      jobs
      |> Enum.map(fn {_name, job} -> job_to_json(job) end)
      |> Enum.reject(&is_nil/1)
      |> Enum.map_join("\n", &Jason.encode!/1)

    content = if lines == "", do: "", else: lines <> "\n"

    case File.mkdir_p(Path.dirname(path)) do
      :ok ->
        case File.write(path, content) do
          :ok -> :ok
          {:error, reason} ->
            Logger.warning("[Kyber.Cron] failed to persist jobs: #{inspect(reason)}")
        end

      {:error, reason} ->
        Logger.warning("[Kyber.Cron] failed to create persist dir: #{inspect(reason)}")
    end
  end

  defp job_to_json(job) do
    {:ok, sched_map} = serialize_schedule(job.schedule)

    %{
      "name" => job.name,
      "schedule" => sched_map,
      "next_run" => DateTime.to_iso8601(job.next_run),
      "fired_count" => job.fired_count,
      "metadata" => job.metadata || %{}
    }
  end

  defp serialize_schedule({:every, ms}),
    do: {:ok, %{"type" => "every", "ms" => ms}}

  defp serialize_schedule({:cron, expr}),
    do: {:ok, %{"type" => "cron", "expr" => expr}}

  defp serialize_schedule({:at, dt}),
    do: {:ok, %{"type" => "at", "datetime" => DateTime.to_iso8601(dt)}}

  defp deserialize_schedule(%{"type" => "every", "ms" => ms}), do: {:ok, {:every, ms}}
  defp deserialize_schedule(%{"type" => "cron", "expr" => expr}), do: {:ok, {:cron, expr}}

  defp deserialize_schedule(%{"type" => "at", "datetime" => dt_str}) do
    case DateTime.from_iso8601(dt_str) do
      {:ok, dt, _} -> {:ok, {:at, dt}}
      _ -> {:error, :invalid_datetime}
    end
  end

  defp deserialize_schedule(_), do: {:error, :unknown_schedule_type}

  # Load persisted jobs from JSONL file.
  defp load_persisted_jobs(%{persist_path: nil} = state), do: state

  defp load_persisted_jobs(%{persist_path: path} = state) do
    if File.exists?(path) do
      now = DateTime.utc_now()

      jobs =
        path
        |> File.stream!()
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.map(fn line ->
          case Jason.decode(line) do
            {:ok, map} -> map
            _ -> nil
          end
        end)
        |> Stream.reject(&is_nil/1)
        |> Enum.reduce(%{}, fn job_map, acc ->
          case restore_job(job_map, now) do
            {:ok, job} -> Map.put(acc, job.name, job)
            {:skip, _reason} -> acc
          end
        end)

      loaded = map_size(jobs)
      if loaded > 0 do
        Logger.info("[Kyber.Cron] reloaded #{loaded} persisted jobs from #{path}")
      end

      %{state | jobs: jobs}
    else
      state
    end
  end

  defp restore_job(job_map, now) do
    with name when is_binary(name) <- Map.get(job_map, "name"),
         sched_map when is_map(sched_map) <- Map.get(job_map, "schedule"),
         {:ok, schedule} <- deserialize_schedule(sched_map) do
      fired_count = Map.get(job_map, "fired_count", 0)
      metadata = Map.get(job_map, "metadata", %{})

      # For one-shot jobs, check if the target time has passed
      next_run =
        case schedule do
          {:at, target_dt} ->
            # If in the past, we'll fire immediately (mark as missed)
            target_dt

          _ ->
            # For recurring jobs, recalculate from now
            compute_next_run(schedule, now)
        end

      job = %{
        name: name,
        schedule: schedule,
        callback: nil,  # callbacks can't be persisted
        next_run: next_run,
        fired_count: fired_count,
        metadata: metadata,
        missed: false
      }

      {:ok, job}
    else
      _ -> {:skip, :invalid_job_data}
    end
  end

  # ── Cron math ─────────────────────────────────────────────────────────────────

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
