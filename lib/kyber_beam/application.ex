defmodule KyberBeam.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("[KyberBeam] starting application")

    children =
      [
        {Kyber.Core, name: Kyber.Core}
      ] ++ web_children()

    opts = [strategy: :one_for_one, name: KyberBeam.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp web_children do
    if Application.get_env(:kyber_beam, :start_web, false) do
      port = Application.get_env(:kyber_beam, :port, 4000)
      [{Kyber.Web.Server, port: port}]
    else
      []
    end
  end
end
