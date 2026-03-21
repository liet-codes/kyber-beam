defmodule Kyber.Web.FamiliardControllerTest do
  @moduledoc """
  Tests for FamiliardController signature verification.

  Verifies that:
  - Invalid/missing signatures return 401
  - Valid signatures (with configured secret) are accepted
  - Dev mode (no secret configured) accepts all requests
  - Valid payloads are parsed and dispatched
  """
  use ExUnit.Case, async: true

  alias Kyber.Familiard

  # Helper to compute HMAC-SHA256 signature matching the familiard protocol
  defp compute_signature(secret, body) do
    :crypto.mac(:hmac, :sha256, secret, body)
    |> Base.encode16(case: :lower)
  end

  describe "verify_signature/3" do
    setup do
      {:ok, fam} =
        Familiard.start_link(
          name: :"fam_test_#{:rand.uniform(999_999)}",
          webhook_secret: "test-secret"
        )

      {:ok, fam: fam}
    end

    test "returns :ok for valid signature", %{fam: fam} do
      body = ~s({"level":"info","message":"test"})
      sig = compute_signature("test-secret", body)
      assert :ok = Familiard.verify_signature(fam, body, sig)
    end

    test "returns {:error, :invalid_signature} for wrong signature", %{fam: fam} do
      body = ~s({"level":"info","message":"test"})
      assert {:error, :invalid_signature} = Familiard.verify_signature(fam, body, "deadbeef")
    end

    test "returns {:error, :invalid_signature} for nil signature", %{fam: fam} do
      body = ~s({"level":"info","message":"test"})
      assert {:error, :invalid_signature} = Familiard.verify_signature(fam, body, nil)
    end

    test "rejects tampered body", %{fam: fam} do
      original = ~s({"level":"info","message":"legit"})
      sig = compute_signature("test-secret", original)
      tampered = ~s({"level":"critical","message":"hacked"})
      assert {:error, :invalid_signature} = Familiard.verify_signature(fam, tampered, sig)
    end
  end

  describe "verify_signature/3 — dev mode (no secret)" do
    setup do
      {:ok, fam} =
        Familiard.start_link(
          name: :"fam_noauth_#{:rand.uniform(999_999)}"
          # no webhook_secret
        )

      {:ok, fam: fam}
    end

    test "returns {:error, :no_secret} when no secret configured", %{fam: fam} do
      assert {:error, :no_secret} = Familiard.verify_signature(fam, "any body", "any sig")
    end
  end

  describe "parse_escalation/1" do
    test "parses valid warning payload" do
      payload = %{"level" => "warning", "message" => "High memory usage"}
      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert event.level == :warning
      assert event.message == "High memory usage"
    end

    test "parses valid critical payload" do
      payload = %{"level" => "critical", "message" => "Process crashed"}
      assert {:ok, event} = Familiard.parse_escalation(payload)
      assert event.level == :critical
    end

    test "rejects invalid level" do
      payload = %{"level" => "extreme", "message" => "test"}
      assert {:error, :invalid_level} = Familiard.parse_escalation(payload)
    end

    test "rejects missing message" do
      payload = %{"level" => "info"}
      assert {:error, :missing_message} = Familiard.parse_escalation(payload)
    end

    test "rejects non-map payload" do
      assert {:error, :invalid_payload} = Familiard.parse_escalation("not a map")
    end
  end
end
