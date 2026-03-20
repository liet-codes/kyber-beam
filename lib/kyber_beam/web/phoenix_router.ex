defmodule Kyber.Web.PhoenixRouter do
  @moduledoc """
  Phoenix Router for the Kyber LiveView Dashboard.

  Routes:
  - `GET /`            → redirect to /dashboard
  - `GET /dashboard`   → Kyber.Web.DashboardLive (overview)
  - `GET /sys`         → Phoenix LiveDashboard (system metrics)
  - `POST /api/familiard/escalate` → Kyber.Web.FamiliardController (bearer auth + sig)
  - `GET  /api/knowledge/notes`    → Kyber.Web.KnowledgeController (bearer auth)
  """

  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Phoenix.LiveDashboard.Router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {Kyber.Web.Layouts, :root}
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
    # Bearer token auth — set KYBER_API_TOKEN env var or :api_token app config.
    # When no token is configured (dev mode), all requests pass through with a warning.
    plug Kyber.Web.Plugs.BearerAuth
  end

  scope "/" do
    pipe_through :browser

    get "/", Kyber.Web.PageController, :redirect_to_dashboard

    live "/dashboard", Kyber.Web.DashboardLive, :overview
    live "/dashboard/deltas", Kyber.Web.DashboardLive, :deltas
    live "/dashboard/nodes", Kyber.Web.DashboardLive, :nodes

    live_dashboard "/sys",
      metrics: Kyber.Telemetry,
      ecto_repos: []
  end

  # Phase 3: Familiard webhook and Knowledge API
  scope "/api" do
    pipe_through :api

    post "/familiard/escalate", Kyber.Web.FamiliardController, :escalate

    get "/knowledge/notes", Kyber.Web.KnowledgeController, :index
    get "/knowledge/notes/*path", Kyber.Web.KnowledgeController, :show
  end
end
