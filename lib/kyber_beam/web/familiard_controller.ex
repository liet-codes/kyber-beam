defmodule Kyber.Web.FamiliardController do
  @moduledoc """
  Phoenix controller for the familiard escalation webhook.

  POST /api/familiard/escalate
  """
  use Phoenix.Controller, formats: [:json]
  require Logger

  def escalate(conn, params) do
    case Kyber.Familiard.parse_escalation(params) do
      {:ok, event} ->
        familiard = familiard_pid()

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
