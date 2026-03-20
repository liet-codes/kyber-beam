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

        # Core OTP components
        {Kyber.Session, name: Kyber.Session},
        {Kyber.Core, name: Kyber.Core},

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
    result = Supervisor.start_link(children, opts)

    # Start a background monitor that watches Delta.Store and logs deaths
    spawn(fn ->
      Process.sleep(2_000)  # Let the tree settle
      monitor_delta_store()
    end)

    result
  end

  defp monitor_delta_store do
    case Process.whereis(:"Elixir.Kyber.Core.Store") do
      nil ->
        Logger.error("[AppMonitor] Delta.Store NOT FOUND at startup!")
        Process.sleep(5_000)
        monitor_delta_store()

      pid ->
        ref = Process.monitor(pid)
        Logger.info("[AppMonitor] Watching Delta.Store pid=#{inspect(pid)}")

        receive do
          {:DOWN, ^ref, :process, ^pid, reason} ->
            Logger.error("[AppMonitor] ⚠️  Delta.Store DIED! reason=#{inspect(reason)}")
            Logger.error("[AppMonitor] Process info was: #{inspect(Process.info(pid))}")

            # Check if supervisor is still alive
            case Process.whereis(Kyber.Core) do
              nil -> Logger.error("[AppMonitor] Kyber.Core supervisor is also DEAD")
              sup_pid -> Logger.error("[AppMonitor] Kyber.Core supervisor alive at #{inspect(sup_pid)}")
            end

            # Re-monitor after restart
            Process.sleep(2_000)
            monitor_delta_store()
        end
    end
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
