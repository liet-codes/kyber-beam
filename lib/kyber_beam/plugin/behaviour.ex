defmodule Kyber.Plugin.Behaviour do
  @moduledoc """
  Behaviour for Kyber plugins.

  All plugins are GenServers managed by `Kyber.Plugin.Manager` (DynamicSupervisor).
  This behaviour defines the contract that every plugin must satisfy beyond
  GenServer's own callbacks.

  ## Required callbacks

    * `name/0` — unique plugin identifier string (e.g. "discord", "llm")
    * `start_link/1` — standard GenServer start_link accepting keyword opts

  ## Optional callbacks

    * `capabilities/0` — list of capability atoms this plugin provides
    * `secrets/0` — list of required secret/config atoms
  """

  @callback name() :: String.t()
  @callback start_link(opts :: keyword()) :: GenServer.on_start()

  # Optional callbacks
  @callback capabilities() :: [atom()]
  @callback secrets() :: [atom()]

  @optional_callbacks [capabilities: 0, secrets: 0]
end
