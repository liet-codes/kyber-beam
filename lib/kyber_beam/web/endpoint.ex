defmodule Kyber.Web.Endpoint do
  @moduledoc """
  Phoenix Endpoint for the Kyber LiveView dashboard.

  Serves the dashboard on port 4001 (configurable).
  The existing Plug/Bandit API server continues on port 4000.

  ## Static assets

  Phoenix and LiveView JavaScript are served from the hex packages'
  priv/static directories via `Plug.Static`, with import maps providing
  module resolution in the browser — no esbuild/npm required.
  """

  use Phoenix.Endpoint, otp_app: :kyber_beam

  # LiveView socket
  socket "/live", Phoenix.LiveView.Socket,
    websocket: [connect_info: [session: {:cookie, "_kyber_session", [sign: true]}]],
    longpoll: false

  # Serve static assets from phoenix and phoenix_live_view hex packages
  plug Plug.Static,
    at: "/assets/phoenix",
    from: {:phoenix, "priv/static"},
    gzip: false

  plug Plug.Static,
    at: "/assets/lv",
    from: {:phoenix_live_view, "priv/static"},
    gzip: false

  plug Plug.Static,
    at: "/assets/dashboard",
    from: {:phoenix_live_dashboard, "priv/static"},
    gzip: false

  # Parse request bodies. The custom body_reader caches the raw bytes in
  # conn.private[:raw_body] for webhook signature verification (familiard).
  plug Plug.Parsers,
    parsers: [:urlencoded, :multipart, :json],
    pass: ["*/*"],
    body_reader: {Kyber.Web.Plugs.RawBodyCache, :read_body, []},
    json_decoder: Phoenix.json_library()

  # Session
  plug Plug.Session,
    store: :cookie,
    key: "_kyber_session",
    signing_salt: "kyber_lv_salt"

  plug Kyber.Web.PhoenixRouter
end
