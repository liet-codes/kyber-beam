defmodule Kyber.CronTest do
  use ExUnit.Case, async: true

  alias Kyber.Cron

  # ── parse_cron/1 ──────────────────────────────────────────────────────────

  describe "parse_cron/1" do
    test "parses wildcard expression" do
      assert {:ok, fields} = Cron.parse_cron("* * * * *")
      assert fields.minutes == Enum.to_list(0..59)
      assert fields.hours == Enum.to_list(0..23)
    end

    test "parses exact values" do
      assert {:ok, fields} = Cron.parse_cron("0 9 1 1 1")
      assert fields.minutes == [0]
      assert fields.hours == [9]
      assert fields.doms == [1]
      assert fields.months == [1]
      assert fields.dows == [1]
    end

    test "parses step syntax */5" do
      assert {:ok, fields} = Cron.parse_cron("*/5 * * * *")
      assert fields.minutes == [0, 5, 10, 15, 20, 25, 30, 35, 40, 45, 50, 55]
    end

    test "parses comma-separated values" do
      assert {:ok, fields} = Cron.parse_cron("0,30 9,17 * * *")
      assert fields.minutes == [0, 30]
      assert fields.hours == [9, 17]
    end

    test "parses named days of week" do
      assert {:ok, fields} = Cron.parse_cron("0 9 * * MON")
      assert fields.dows == [1]
    end

    test "parses MON,WED,FRI" do
      assert {:ok, fields} = Cron.parse_cron("0 9 * * MON,WED,FRI")
      assert fields.dows == [1, 3, 5]
    end

    test "parses SUN as 0" do
      assert {:ok, fields} = Cron.parse_cron("0 0 * * SUN")
      assert fields.dows == [0]
    end

    test "rejects expression with wrong number of fields" do
      assert {:error, :invalid_cron} = Cron.parse_cron("0 9 * *")
      assert {:error, :invalid_cron} = Cron.parse_cron("0 9 * * MON extra")
    end

    test "rejects values out of range" do
      assert {:error, _} = Cron.parse_cron("60 9 * * *")   # minute 60 invalid
      assert {:error, _} = Cron.parse_cron("0 25 * * *")   # hour 25 invalid
    end
  end

  # ── compute_next_run/2 ────────────────────────────────────────────────────

  describe "compute_next_run/2" do
    test ":every schedule adds interval to from" do
      from = ~U[2025-01-01 10:00:00Z]
      next = Cron.compute_next_run({:every, 30_000}, from)
      # Compare ignoring microseconds sub-precision
      assert DateTime.diff(next, ~U[2025-01-01 10:00:30Z], :second) == 0
    end

    test ":at schedule returns the datetime as-is" do
      from = ~U[2025-01-01 10:00:00Z]
      target = ~U[2025-12-31 23:59:00Z]
      assert Cron.compute_next_run({:at, target}, from) == target
    end

    test ":cron schedule finds next matching time" do
      # 9 AM every Monday
      # From a Wednesday, the next match should be Monday
      from = ~U[2025-01-15 10:00:00Z]  # Wednesday 2025-01-15
      next = Cron.compute_next_run({:cron, "0 9 * * MON"}, from)

      # Next Monday is 2025-01-20
      assert next.hour == 9
      assert next.minute == 0
      # Should be a Monday (day_of_week 1 in Elixir = Mon)
      assert Date.day_of_week(DateTime.to_date(next)) == 1
    end

    test ":cron matches the very next minute if eligible" do
      # Every minute
      from = ~U[2025-01-01 10:00:30Z]
      next = Cron.compute_next_run({:cron, "* * * * *"}, from)
      assert next.hour == 10
      assert next.minute == 1
      assert next.second == 0
    end
  end

  # ── GenServer: add/remove/list jobs ──────────────────────────────────────

  describe "job management" do
    setup do
      {:ok, pid} = Cron.start_link(name: nil, core: nil, check_interval: 100_000)
      %{pid: pid}
    end

    test "add_job/4 adds a job", %{pid: pid} do
      assert :ok = Cron.add_job(pid, "test-job", {:every, :timer.minutes(30)})
      jobs = Cron.list_jobs(pid)
      assert Enum.any?(jobs, fn j -> j.name == "test-job" end)
    end

    test "list_jobs/1 includes next_run and fired_count", %{pid: pid} do
      Cron.add_job(pid, "my-job", {:every, 60_000})
      [job | _] = Cron.list_jobs(pid) |> Enum.filter(&(&1.name == "my-job"))

      assert %DateTime{} = job.next_run
      assert job.fired_count == 0
    end

    test "remove_job/2 removes an existing job", %{pid: pid} do
      Cron.add_job(pid, "removable", {:every, 1_000})
      assert :ok = Cron.remove_job(pid, "removable")
      jobs = Cron.list_jobs(pid)
      refute Enum.any?(jobs, fn j -> j.name == "removable" end)
    end

    test "remove_job/2 returns error for unknown job", %{pid: pid} do
      assert {:error, :not_found} = Cron.remove_job(pid, "ghost")
    end

    test "add_job/4 with callback stores callback", %{pid: pid} do
      cb = fn _job -> :fired end
      Cron.add_job(pid, "with-cb", {:every, 60_000}, cb)
      jobs = Cron.list_jobs(pid)
      assert Enum.any?(jobs, fn j -> j.name == "with-cb" end)
    end
  end

  # ── add_reminder ─────────────────────────────────────────────────────────

  describe "add_reminder/3" do
    setup do
      {:ok, pid} = Cron.start_link(name: nil, core: nil, check_interval: 100_000)
      %{pid: pid}
    end

    test "adds a one-shot reminder", %{pid: pid} do
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      assert :ok = Cron.add_reminder(pid, "Check the thing", future)

      jobs = Cron.list_jobs(pid)
      reminder = Enum.find(jobs, fn j -> String.starts_with?(j.name, "reminder:") end)
      assert reminder != nil
      assert match?({:at, _}, reminder.schedule)
    end
  end

  # ── Firing mechanism ──────────────────────────────────────────────────────

  describe "job firing" do
    test "interval job fires and callback is called" do
      test_pid = self()

      {:ok, pid} = Cron.start_link(
        name: nil,
        core: nil,
        check_interval: 50  # check every 50ms
      )

      callback = fn _job -> send(test_pid, :job_fired) end
      # Schedule a job to fire in 1ms
      Cron.add_job(pid, "fast-job", {:every, 1}, callback)

      assert_receive :job_fired, 500
      GenServer.stop(pid)
    end

    test "one-shot job fires once and is removed" do
      test_pid = self()

      {:ok, pid} = Cron.start_link(
        name: nil,
        core: nil,
        check_interval: 50
      )

      past = DateTime.add(DateTime.utc_now(), -1, :second)
      callback = fn _job -> send(test_pid, :one_shot_fired) end
      Cron.add_job(pid, "one-shot", {:at, past}, callback)

      assert_receive :one_shot_fired, 500

      # Wait a bit and verify the job was removed
      Process.sleep(100)
      jobs = Cron.list_jobs(pid)
      refute Enum.any?(jobs, fn j -> j.name == "one-shot" end)

      GenServer.stop(pid)
    end

    test "emits cron.fired delta when core is set" do
      {:ok, core} = Kyber.Core.start_link(name: :"TestCronCore#{:rand.uniform(99999)}")
      test_pid = self()

      # Subscribe to core's delta store
      store_name = :"Elixir.Kyber.Delta.StoreTestCronCore#{:rand.uniform(99999)}"
      # Easier: subscribe at the core level
      # Actually, let's use a simpler approach — listen for the delta in the store

      {:ok, pid} = Cron.start_link(
        name: nil,
        core: core,
        check_interval: 50
      )

      # Subscribe to delta store
      store = Kyber.Core.query_deltas(core)
      _ = store

      # Add a fast job
      Cron.add_job(pid, "emit-test", {:every, 1})

      # Give it time to fire
      Process.sleep(200)

      # Check the delta store
      deltas = Kyber.Core.query_deltas(core, kind: "cron.fired")
      assert length(deltas) >= 1

      fired = hd(deltas)
      assert fired.kind == "cron.fired"
      assert fired.payload["job_name"] == "emit-test"
      assert fired.origin == {:cron, "emit-test"}

      GenServer.stop(pid)
      Supervisor.stop(core)
    end
  end

  # ── get_core ──────────────────────────────────────────────────────────────

  describe "get_core/1" do
    test "returns the configured core" do
      {:ok, pid} = Cron.start_link(name: nil, core: :test_core, check_interval: 100_000)
      assert Cron.get_core(pid) == :test_core
      GenServer.stop(pid)
    end
  end
end
