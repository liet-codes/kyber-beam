defmodule Kyber.IntrospectionTest do
  use ExUnit.Case, async: true

  alias Kyber.Introspection

  # ── memory_summary ────────────────────────────────────────────────────────

  describe "memory_summary/0" do
    test "returns a map with all expected MB keys" do
      result = Introspection.memory_summary()

      assert is_map(result)

      for key <- [:total_mb, :processes_mb, :system_mb, :atom_mb, :binary_mb, :ets_mb, :code_mb] do
        assert Map.has_key?(result, key), "missing key: #{key}"
        assert is_number(result[key]), "#{key} should be a number"
      end
    end

    test "total_mb is positive" do
      assert Introspection.memory_summary().total_mb > 0
    end

    test "processes_mb is positive" do
      assert Introspection.memory_summary().processes_mb > 0
    end
  end

  # ── system_info ───────────────────────────────────────────────────────────

  describe "system_info/0" do
    test "returns a map with all expected keys" do
      result = Introspection.system_info()

      assert is_map(result)

      for key <- [
            :schedulers,
            :schedulers_online,
            :process_count,
            :process_limit,
            :port_count,
            :atom_count,
            :atom_limit,
            :uptime_seconds,
            :otp_release,
            :erts_version
          ] do
        assert Map.has_key?(result, key), "missing key: #{key}"
      end
    end

    test "process_count is positive" do
      assert Introspection.system_info().process_count > 0
    end

    test "schedulers is positive" do
      assert Introspection.system_info().schedulers > 0
    end

    test "uptime_seconds is non-negative" do
      assert Introspection.system_info().uptime_seconds >= 0
    end

    test "otp_release is a non-empty string" do
      release = Introspection.system_info().otp_release
      assert is_binary(release)
      assert release != ""
    end
  end

  # ── top_processes ─────────────────────────────────────────────────────────

  describe "top_processes/1" do
    test "returns a list" do
      result = Introspection.top_processes(10)
      assert is_list(result)
    end

    test "returns at most N processes" do
      result = Introspection.top_processes(5)
      assert length(result) <= 5
    end

    test "each entry has required keys" do
      result = Introspection.top_processes(3)

      for entry <- result do
        assert Map.has_key?(entry, :pid)
        assert Map.has_key?(entry, :name)
        assert Map.has_key?(entry, :memory_kb)
        assert Map.has_key?(entry, :message_queue_len)
        assert Map.has_key?(entry, :reductions)
        assert Map.has_key?(entry, :current_function)
      end
    end

    test "sorted descending by memory_kb" do
      result = Introspection.top_processes(10)

      memory_values = Enum.map(result, & &1.memory_kb)
      assert memory_values == Enum.sort(memory_values, :desc)
    end

    test "pid and name are strings" do
      result = Introspection.top_processes(5)

      for entry <- result do
        assert is_binary(entry.pid)
        assert is_binary(entry.name)
      end
    end

    test "returns processes when n is 1" do
      result = Introspection.top_processes(1)
      assert length(result) == 1
    end
  end

  # ── ets_tables ────────────────────────────────────────────────────────────

  describe "ets_tables/0" do
    test "returns a list" do
      result = Introspection.ets_tables()
      assert is_list(result)
    end

    test "returns at least one table" do
      # There are always system ETS tables
      result = Introspection.ets_tables()
      assert length(result) > 0
    end

    test "each entry has required keys" do
      result = Introspection.ets_tables()

      for entry <- result do
        assert Map.has_key?(entry, :id)
        assert Map.has_key?(entry, :name)
        assert Map.has_key?(entry, :size)
        assert Map.has_key?(entry, :memory_kb)
        assert Map.has_key?(entry, :type)
        assert Map.has_key?(entry, :owner)
      end
    end

    test "name and type are strings" do
      [first | _] = Introspection.ets_tables()
      assert is_binary(first.name)
      assert is_binary(first.type)
    end
  end

  # ── inspect_process ───────────────────────────────────────────────────────

  describe "inspect_process/1" do
    test "returns error for nonexistent process" do
      result = Introspection.inspect_process(:__kyber_nonexistent_process_xyz__)
      assert {:error, msg} = result
      assert is_binary(msg)
    end

    test "returns process info for a known process" do
      # The test process itself is alive; look up by PID via a registered name
      # We'll register a test process temporarily
      pid = self()
      name = :kyber_introspection_test_proc
      Process.register(pid, name)

      on_exit(fn ->
        if Process.whereis(name) == pid do
          Process.unregister(name)
        end
      end)

      result = Introspection.inspect_process(name)
      assert is_map(result)
      assert Map.has_key?(result, :pid)
      assert Map.has_key?(result, :memory_kb)
      assert Map.has_key?(result, :status)

      Process.unregister(name)
    end
  end

  # ── queue_health ──────────────────────────────────────────────────────────

  describe "queue_health/1" do
    test "returns a list" do
      result = Introspection.queue_health(100)
      assert is_list(result)
    end

    test "entries have pid, name, queue_len" do
      # With a very low threshold we'll get some results
      result = Introspection.queue_health(0)

      for entry <- result do
        assert Map.has_key?(entry, :pid)
        assert Map.has_key?(entry, :name)
        assert Map.has_key?(entry, :queue_len)
        assert is_binary(entry.pid)
        assert is_binary(entry.name)
        assert is_integer(entry.queue_len)
      end
    end

    test "sorted descending by queue_len" do
      result = Introspection.queue_health(0)
      lens = Enum.map(result, & &1.queue_len)
      assert lens == Enum.sort(lens, :desc)
    end
  end

  # ── io_stats ──────────────────────────────────────────────────────────────

  describe "io_stats/0" do
    test "returns input_mb and output_mb" do
      result = Introspection.io_stats()
      assert is_map(result)
      assert Map.has_key?(result, :input_mb)
      assert Map.has_key?(result, :output_mb)
      assert is_number(result.input_mb)
      assert is_number(result.output_mb)
    end
  end

  # ── port_info ─────────────────────────────────────────────────────────────

  describe "port_info/0" do
    test "returns total_ports and sample" do
      result = Introspection.port_info()
      assert is_map(result)
      assert Map.has_key?(result, :total_ports)
      assert Map.has_key?(result, :sample)
      assert is_integer(result.total_ports)
      assert is_list(result.sample)
    end
  end

  # ── gc_process ────────────────────────────────────────────────────────────

  describe "gc_process/1" do
    test "returns error for nonexistent process" do
      result = Introspection.gc_process(:__kyber_nonexistent_gc_proc_xyz__)
      assert {:error, msg} = result
      assert is_binary(msg)
    end

    test ":all returns scope all_processes" do
      result = Introspection.gc_process(:all)
      assert is_map(result)
      assert result.scope == "all_processes"
      assert Map.has_key?(result, :before_mb)
      assert Map.has_key?(result, :after_mb)
      assert Map.has_key?(result, :freed_mb)
    end

    test "named process returns before/after/freed" do
      pid = self()
      name = :kyber_introspection_gc_test_proc
      Process.register(pid, name)

      on_exit(fn ->
        if Process.whereis(name) == pid do
          Process.unregister(name)
        end
      end)

      result = Introspection.gc_process(name)
      assert is_map(result)
      assert Map.has_key?(result, :process)
      assert Map.has_key?(result, :before_kb)
      assert Map.has_key?(result, :after_kb)
      assert Map.has_key?(result, :freed_kb)

      Process.unregister(name)
    end
  end
end
