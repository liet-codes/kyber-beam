defmodule Mix.Tasks.Kyber.Query do
  @shortdoc "Query deltas from a running Kyber instance"
  @moduledoc """
  Query deltas from Kyber's delta store.

  ## Usage

      mix kyber.query
      mix kyber.query --kind message.received
      mix kyber.query --limit 10
      mix kyber.query --kind error.route --limit 5

  ## Options

    * `--kind`  — filter by delta kind
    * `--limit` — maximum number of results (default: 20)

  """

  use Mix.Task

  @impl Mix.Task
  def run(args) do
    {_flags, opts} = Kyber.CLI.parse_args(args)

    kind = opts["kind"]
    limit = opts["limit"] && String.to_integer(opts["limit"])

    {:ok, _} = Application.ensure_all_started(:kyber_beam)

    filters = []
    filters = if kind, do: [{:kind, kind} | filters], else: filters
    filters = if limit, do: [{:limit, limit} | filters], else: filters

    deltas = Kyber.Core.query_deltas(Kyber.Core, filters)

    if Enum.empty?(deltas) do
      Mix.shell().info("No deltas found.")
    else
      Mix.shell().info("Found #{length(deltas)} delta(s):\n")

      Enum.each(deltas, fn delta ->
        Mix.shell().info(Kyber.CLI.format_delta(delta))
        Mix.shell().info("")
      end)
    end
  end
end
