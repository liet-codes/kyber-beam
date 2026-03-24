defmodule KyberBeam.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("[KyberBeam] starting application v#{Application.spec(:kyber_beam, :vsn)}")

    vault_path = Application.get_env(:kyber_beam, :vault_path, Path.expand("~/.kyber/vault"))
    heartbeat_interval = Application.get_env(:kyber_beam, :heartbeat_interval, nil)

    discord_token = Application.get_env(:kyber_beam, :discord_bot_token)
    discord_connect = Application.get_env(:kyber_beam, :discord_connect, false)

    children =
      [
        # PubSub for Phoenix LiveView
        {Phoenix.PubSub, name: Kyber.PubSub},

        # Core OTP components — Core must start before Session so the delta
        # store is ready before Session can rehydrate from it.
        {Kyber.Core, name: Kyber.Core},
        {Kyber.Session, name: Kyber.Session},

        # Hot code deployment (Phase 2)
        {Kyber.Deployment, name: Kyber.Deployment},

        # Phase 3: Knowledge graph
        {Kyber.Knowledge, name: Kyber.Knowledge, vault_path: vault_path},

        # Phase 3: Cron scheduler
        {Kyber.Cron,
         name: Kyber.Cron,
         core: Kyber.Core,
         heartbeat_interval: heartbeat_interval},

        # Memory consolidator — must start after Delta.Store and Knowledge
        {Kyber.Memory.Consolidator,
         name: Kyber.Memory.Consolidator,
         core: Kyber.Core},

        # LLM plugin (Anthropic API)
        {Kyber.Plugin.LLM,
         core: Kyber.Core,
         session: Kyber.Session},

        # Discord plugin (Stilgar bot)
        {Kyber.Plugin.Discord,
         token: discord_token,
         core: Kyber.Core,
         connect: discord_connect}
      ]
      |> then(&(&1 ++ web_children()))
      |> then(&(&1 ++ phoenix_children()))
      |> then(&(&1 ++ [{Kyber.Distribution, name: Kyber.Distribution}]))  # LAST — subscribes to Core's children

    opts = [strategy: :one_for_one, name: KyberBeam.Supervisor, max_restarts: 10, max_seconds: 60]
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

  defp phoenix_children do
    # Start Phoenix Endpoint unless explicitly disabled (e.g. in tests)
    if Application.get_env(:kyber_beam, Kyber.Web.Endpoint, [])
       |> Keyword.get(:server, true) do
      [Kyber.Web.Endpoint]
    else
      []
    end
  end
end
