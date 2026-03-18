defmodule Kyber.FamiliardTest do
  use ExUnit.Case, async: true

  alias Kyber.Familiard

  # ── parse_escalation/1 ───────────────────────────────────────────────────

  describe "parse_escalation/1" do
    test "parses a valid critical escalation" do
      payload = %{
        "level" => "critical",
        "message" => "Memory threshold exceeded",
        "context" => %{"memory_mb" => 4200, "process" => "kyber"},
        "timestamp" => "2025-01-15T09:30:00Z"
      }

      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert event.level == :critical
      assert event.message == "Memory threshold exceeded"
      assert event.context["memory_mb"] == 4200
      assert event.timestamp == "2025-01-15T09:30:00Z"
    end

    test "parses warning level" do
      payload = %{"level" => "warning", "message" => "CPU spike"}
      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert event.level == :warning
    end

    test "parses info level" do
      payload = %{"level" => "info", "message" => "Service restarted"}
      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert event.level == :info
    end

    test "defaults context to empty map when missing" do
      payload = %{"level" => "info", "message" => "OK"}
      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert event.context == %{}
    end

    test "auto-generates timestamp when missing" do
      payload = %{"level" => "info", "message" => "No timestamp"}
      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert is_binary(event.timestamp)
    end

    test "rejects missing level" do
      payload = %{"message" => "No level here"}
      assert {:error, :missing_level} = Familiard.parse_escalation(payload)
    end

    test "rejects invalid level" do
      payload = %{"level" => "disaster", "message" => "Unknown level"}
      assert {:error, :invalid_level} = Familiard.parse_escalation(payload)
    end

    test "rejects missing message" do
      payload = %{"level" => "warning"}
      assert {:error, :missing_message} = Familiard.parse_escalation(payload)
    end

    test "rejects empty message" do
      payload = %{"level" => "info", "message" => ""}
      assert {:error, :invalid_message} = Familiard.parse_escalation(payload)
    end

    test "rejects non-map input" do
      assert {:error, :invalid_payload} = Familiard.parse_escalation("not a map")
      assert {:error, :invalid_payload} = Familiard.parse_escalation(nil)
    end
  end

  # ── GenServer: emit_escalation/2 ─────────────────────────────────────────

  describe "emit_escalation/2" do
    test "emits a familiard.escalation delta when core is set" do
      {:ok, core} = Kyber.Core.start_link(name: :"TestFamCore#{:rand.uniform(99999)}")

      {:ok, pid} = Familiard.start_link(name: nil, core: core)

      # Snapshot delta count before emit
      before_count = length(Kyber.Core.query_deltas(core, kind: "familiard.escalation"))

      event = %{
        level: :critical,
        message: "Disk full",
        context: %{"disk_gb" => 0},
        timestamp: "2025-01-01T00:00:00Z"
      }

      assert :ok = Familiard.emit_escalation(pid, event)

      # Give the delta time to be appended
      Process.sleep(50)

      deltas = Kyber.Core.query_deltas(core, kind: "familiard.escalation")
      # There should be exactly one more delta than before
      assert length(deltas) == before_count + 1

      # Find our specific delta
      delta = Enum.find(deltas, fn d ->
        d.payload["message"] == "Disk full"
      end)

      assert delta != nil
      assert delta.kind == "familiard.escalation"
      assert delta.payload["level"] == "critical"
      assert delta.payload["message"] == "Disk full"
      assert delta.origin == {:system, "familiard"}

      Supervisor.stop(core)
      GenServer.stop(pid)
    end

    test "does not crash when core is nil" do
      {:ok, pid} = Familiard.start_link(name: nil, core: nil)

      event = %{
        level: :info,
        message: "Just testing",
        context: %{},
        timestamp: "2025-01-01T00:00:00Z"
      }

      assert :ok = Familiard.emit_escalation(pid, event)
      GenServer.stop(pid)
    end
  end

  # ── endpoint/1 ───────────────────────────────────────────────────────────

  describe "endpoint/1" do
    test "returns configured endpoint" do
      {:ok, pid} = Familiard.start_link(
        name: nil,
        core: nil,
        endpoint: "http://familiard.local:9000"
      )

      assert Familiard.endpoint(pid) == "http://familiard.local:9000"
      GenServer.stop(pid)
    end

    test "uses default endpoint when not configured" do
      {:ok, pid} = Familiard.start_link(name: nil, core: nil)
      assert Familiard.endpoint(pid) =~ "localhost"
      GenServer.stop(pid)
    end
  end

  # ── get_status/1 ─────────────────────────────────────────────────────────

  describe "get_status/1" do
    test "returns error when familiard is not running" do
      {:ok, pid} = Familiard.start_link(
        name: nil,
        core: nil,
        endpoint: "http://localhost:19999"  # nothing running here
      )

      result = Familiard.get_status(pid)
      # Familiard isn't running so we expect an error
      assert match?({:error, _}, result)

      GenServer.stop(pid)
    end
  end

  # ── Integration with reducer ──────────────────────────────────────────────

  describe "reducer integration" do
    test "familiard.escalation delta triggers reducer effects" do
      state = %Kyber.State{}

      critical_delta = Kyber.Delta.new(
        "familiard.escalation",
        %{"level" => "critical", "message" => "System meltdown"},
        {:system, "familiard"}
      )

      {_new_state, effects} = Kyber.Reducer.reduce(state, critical_delta)
      assert length(effects) == 1
      assert hd(effects).type == :llm_call

      warning_delta = Kyber.Delta.new(
        "familiard.escalation",
        %{"level" => "warning", "message" => "High CPU"},
        {:system, "familiard"}
      )

      {_new_state, warning_effects} = Kyber.Reducer.reduce(state, warning_delta)
      assert length(warning_effects) == 1

      info_delta = Kyber.Delta.new(
        "familiard.escalation",
        %{"level" => "info", "message" => "All good"},
        {:system, "familiard"}
      )

      {_new_state, info_effects} = Kyber.Reducer.reduce(state, info_delta)
      assert info_effects == []
    end
  end
end
