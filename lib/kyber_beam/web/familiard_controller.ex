defmodule Kyber.Web.FamiliardController do
  @moduledoc """
  Phoenix controller for the familiard escalation webhook.

  POST /api/familiard/escalate

  Signature validation: all requests must carry a valid
  `x-familiard-signature` header (HMAC-SHA256 hex of the raw request body)
  when the familiard webhook_secret is configured. Requests that fail
  signature validation are rejected with HTTP 401. When no secret is
  configured (dev mode), the check is skipped with a warning.
  """
  use Phoenix.Controller, formats: [:json]
  require Logger

  def escalate(conn, params) do
    familiard = familiard_pid()

    # Verify webhook signature before processing the payload.
    # raw_body is cached by the RawBodyCacheParser plug in the router.
    signature = conn |> get_req_header("x-familiard-signature") |> List.first()
    raw_body = conn.private[:raw_body] || ""

    sig_result =
      if familiard do
        Kyber.Familiard.verify_signature(familiard, raw_body, signature)
      else
        # No familiard process — dev mode, skip signature check
        {:error, :no_secret}
      end

    case sig_result do
      {:error, :invalid_signature} ->
        Logger.warning("[FamiliardController] invalid signature from #{conn.remote_ip |> :inet.ntoa()}")

        conn
        |> put_status(401)
        |> json(%{ok: false, error: "invalid signature"})

      _ ->
        # :ok (valid) or {:error, :no_secret} (dev mode — pass through)
        process_escalation(conn, params, familiard, sig_result)
    end
  end

  defp process_escalation(conn, params, familiard, sig_result) do
    if sig_result == {:error, :no_secret} do
      Logger.debug("[FamiliardController] no webhook_secret configured — skipping signature check")
    end

    case Kyber.Familiard.parse_escalation(params) do
      {:ok, event} ->
        if familiard do
          Kyber.Familiard.emit_escalation(familiard, event)
        end

        Logger.info("[FamiliardController] escalation received: #{event.level} — #{event.message}")
        json(conn, %{ok: true, level: to_string(event.level)})

      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{ok: false, error: to_string(reason)})
    end
  end

  defp familiard_pid do
    Process.whereis(Kyber.Familiard)
  end
end
