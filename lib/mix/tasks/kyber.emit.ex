defmodule Mix.Tasks.Kyber.Emit do
  @shortdoc "Emit a delta into a running Kyber instance"
  @moduledoc """
  Emit a delta from the command line.

  ## Usage

      mix kyber.emit --kind message.received --payload '{"text":"hello"}'
      mix kyber.emit --kind plugin.loaded --payload '{"name":"my_plugin"}' --origin system

  ## Options

    * `--kind`    — delta kind (required)
    * `--payload` — JSON object payload (default: `{}`)
    * `--origin`  — origin type: system, human, channel (default: system)
    * `--dry-run` — print the delta without emitting it

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {flags, opts} = Kyber.CLI.parse_args(args)
    dry_run = "--dry-run" in flags

    kind = opts["kind"]

    unless kind do
      Mix.raise("--kind is required. Example: mix kyber.emit --kind message.received --payload '{}'")
    end

    payload =
      case opts["payload"] do
        nil -> %{}
        json_str ->
          case Kyber.CLI.decode_json(json_str) do
            {:ok, map} -> map
            {:error, msg} -> Mix.raise(msg)
          end
      end

    origin = parse_origin(opts["origin"])
    delta = Kyber.Delta.new(kind, payload, origin)

    if dry_run do
      Mix.shell().info("[dry-run] Would emit:")
      Mix.shell().info(Kyber.CLI.format_delta(delta))
    else
      {:ok, _} = Application.ensure_all_started(:kyber_beam)
      :ok = Kyber.Core.emit(Kyber.Core, delta)
      Mix.shell().info("✓ emitted #{delta.id}")
      Mix.shell().info(Kyber.CLI.format_delta(delta))
    end
  end

  defp parse_origin("human"), do: {:human, "cli"}
  defp parse_origin("system"), do: {:system, "cli"}
  defp parse_origin("channel"), do: {:channel, "cli", "cli", "cli"}
  defp parse_origin(_), do: {:system, "cli"}
end
