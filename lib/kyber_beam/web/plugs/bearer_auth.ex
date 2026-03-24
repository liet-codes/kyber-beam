defmodule Kyber.Web.Plugs.BearerAuth do
  @moduledoc """
  Plug that enforces Bearer token authentication on the `/api` scope.

  The expected token is read from `:kyber_beam, :api_token` app config (or the
  `KYBER_API_TOKEN` environment variable at runtime). If no token is configured,
  ALL requests are accepted with a warning logged at startup — this preserves
  developer ergonomics while making the misconfiguration visible.

  Requests must carry:

      Authorization: Bearer <token>

  Non-matching or missing tokens receive HTTP 401.

  ## Config

      # config/dev.exs
      config :kyber_beam, :api_token, "dev-secret-change-me"

      # runtime: set KYBER_API_TOKEN env var, or:
      config :kyber_beam, :api_token, System.get_env("KYBER_API_TOKEN")
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]
  require Logger

  @behaviour Plug

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    # Skip auth for health check (no token required for /health)
    if conn.method == "GET" and conn.path_info == ["health"] do
      conn
    else
      configured_token = api_token()

      if is_nil(configured_token) or configured_token == "" do
        # No token configured — dev mode. Log a warning on every request so it
        # shows up in dev logs (the startup warning may scroll away).
        Logger.debug("[BearerAuth] no API token configured — skipping auth (dev mode)")
        conn
      else
        case get_bearer_token(conn) do
          {:ok, token} ->
            if Plug.Crypto.secure_compare(token, configured_token) do
              conn
            else
              conn
              |> put_status(401)
              |> json(%{ok: false, error: "unauthorized"})
              |> halt()
            end

          _ ->
            conn
            |> put_status(401)
            |> json(%{ok: false, error: "unauthorized"})
            |> halt()
        end
      end
    end
  end

  # Extract the Bearer token from the Authorization header.
  defp get_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> {:ok, String.trim(token)}
      _ -> :missing
    end
  end

  defp api_token do
    Application.get_env(:kyber_beam, :api_token) ||
      System.get_env("KYBER_API_TOKEN")
  end
end
