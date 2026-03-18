defmodule Mix.Tasks.Kyber.Status do
  @shortdoc "Show current Kyber system status"
  @moduledoc """
  Display the current status of a running Kyber instance.

  Shows active plugins, session count, recent errors, and system state.

  ## Usage

      mix kyber.status

  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    {:ok, _} = Application.ensure_all_started(:kyber_beam)

    state = Kyber.Core.get_state(Kyber.Core)
    plugins = Kyber.Core.list_plugins(Kyber.Core)

    sessions =
      if Process.whereis(Kyber.Session) do
        Kyber.Session.list_sessions(Kyber.Session)
      else
        []
      end

    output = Kyber.CLI.format_state(state, plugins, sessions)
    Mix.shell().info(output)
  end
end
