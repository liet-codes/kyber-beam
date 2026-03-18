defmodule Kyber.Web.PageController do
  use Phoenix.Controller, formats: [:html]

  def redirect_to_dashboard(conn, _params) do
    redirect(conn, to: "/dashboard")
  end
end
