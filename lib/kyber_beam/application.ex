defmodule KyberBeam.Application do
  @moduledoc false

  use Application
  require Logger

  @impl true
  def start(_type, _args) do
    Logger.info("[KyberBeam] starting application v#{Application.spec(:kyber_beam, :vsn)}")

    # Populate :persistent_term config cache before any children start
    Kyber.Config.load!()

    vault_path = Application.get_env(:kyber_beam, :vault_path, Path.expand("~/.kyber/vault"))
    heartbeat_interval = Application.get_env(:kyber_beam, :heartbeat_interval, nil)

    # Supervision strategy: :one_for_one
    #
    # Children have startup ordering dependencies (Session before Core,
    # Knowledge before LLM plugin, etc.), but :one_for_one is acceptable
    # because:
    #   1. All children register under well-known names (atoms). When a
    #      child restarts, it re-registers the same name, so siblings that
    #      reference it by name automatically resolve to the new PID.
    #   2. Core and its plugins are self-contained supervisors — a plugin
    #      crash restarts within Core's subtree, not the whole app.
    #   3. The ordering dependency is only at initial boot (handled by list
    #      order). After boot, each child can restart independently.
    #
    # If we later add children whose crashes invalidate sibling state
    # (e.g., shared ETS tables), switch to :rest_for_one.

    children =
      [
        # PubSub for Phoenix LiveView
        {Phoenix.PubSub, name: Kyber.PubSub},

        # Core OTP components
        {Kyber.Session, name: Kyber.Session},

        # Kyber.Core starts with initial plugins routed through Plugin.Manager.
        # This ensures they appear in the plugin list, are hot-reloadable, and
        # emit "plugin.loaded" deltas — rather than bypassing the manager as
        # direct Application supervisor children (P2-1 fix).
        {Kyber.Core,
         name: Kyber.Core,
         plugins: [
           # LLM plugin — reads auth from ~/.openclaw/agents/main/agent/auth-profiles.json
           {Kyber.Plugin.LLM, [core: Kyber.Core, session: Kyber.Session]},
           # Discord plugin — reads token from app config / DISCORD_BOT_TOKEN env
           {Kyber.Plugin.Discord, [core: Kyber.Core]}
         ]},

        # Task.Supervisor for Deployment async tasks (supervised, not ad-hoc)
        {Task.Supervisor, name: Kyber.Deployment.TaskSupervisor},

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
         core: Kyber.Core}
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
