defmodule Kyber.CLI do
  @moduledoc """
  CLI utilities shared by Kyber Mix tasks.

  Provides helpers for argument parsing, output formatting, and
  connecting to a running Kyber instance.
  """

  @doc """
  Parse key=value pairs and flags from a list of string args.

  Returns `{flags, options}` where:
  - `flags` is a list of bare strings (e.g. `["--verbose"]`)
  - `options` is a map of `"key" => "value"` pairs

  ## Examples

      iex> Kyber.CLI.parse_args(["--kind", "message.received", "--payload", ~s({"text":"hi"})])
      {[], %{"kind" => "message.received", "payload" => ~s({"text":"hi"})}}

      iex> Kyber.CLI.parse_args(["--verbose"])
      {["--verbose"], %{}}
  """
  @spec parse_args([String.t()]) :: {[String.t()], map()}
  def parse_args(args) do
    parse_args(args, [], %{})
  end

  defp parse_args([], flags, opts), do: {Enum.reverse(flags), opts}

  defp parse_args(["--" <> key | [value | rest] = tail], flags, opts) do
    if String.starts_with?(value, "--") do
      # value is actually another flag — treat key as a bare flag
      parse_args(tail, ["--" <> key | flags], opts)
    else
      parse_args(rest, flags, Map.put(opts, key, value))
    end
  end

  defp parse_args(["--" <> _key = flag | rest], flags, opts) do
    parse_args(rest, [flag | flags], opts)
  end

  defp parse_args([arg | rest], flags, opts) do
    parse_args(rest, [arg | flags], opts)
  end

  @doc """
  Format a delta for human-readable CLI output.
  """
  @spec format_delta(Kyber.Delta.t()) :: String.t()
  def format_delta(%Kyber.Delta{} = delta) do
    ts = DateTime.from_unix!(delta.ts, :millisecond) |> DateTime.to_string()
    origin = Kyber.Delta.Origin.serialize(delta.origin) |> format_origin()

    payload_str =
      delta.payload
      |> Jason.encode!(pretty: true)
      |> String.split("\n")
      |> Enum.map(&("  " <> &1))
      |> Enum.join("\n")

    """
    [#{delta.kind}] #{delta.id}
      ts:      #{ts}
      origin:  #{origin}
      parent:  #{delta.parent_id || "—"}
      payload:
    #{payload_str}
    """
    |> String.trim_trailing()
  end

  @doc """
  Format the current Kyber state for CLI output.
  """
  @spec format_state(Kyber.State.t(), [String.t()], [String.t()]) :: String.t()
  def format_state(%Kyber.State{} = state, plugins \\ [], sessions \\ []) do
    plugin_list =
      case plugins do
        [] -> "  (none)"
        ps -> ps |> Enum.map(&"  • #{&1}") |> Enum.join("\n")
      end

    session_list =
      case sessions do
        [] -> "  (none)"
        ss -> ss |> Enum.map(&"  • #{&1}") |> Enum.join("\n")
      end

    error_list =
      case state.errors do
        [] -> "  (none)"
        es ->
          es
          |> Enum.map(fn e ->
            "  • [#{e[:delta_id] || "?"}] #{inspect(e)}"
          end)
          |> Enum.join("\n")
      end

    """
    ── Kyber Status ──────────────────────────────────────
    Plugins (#{length(plugins)}):
    #{plugin_list}

    Sessions (#{length(sessions)}):
    #{session_list}

    Recent Errors (#{length(state.errors)}):
    #{error_list}
    ─────────────────────────────────────────────────────
    """
    |> String.trim()
  end

  @doc """
  Decode a JSON string to a map, returning an error string on failure.
  """
  @spec decode_json(String.t()) :: {:ok, map()} | {:error, String.t()}
  def decode_json(json_str) do
    case Jason.decode(json_str) do
      {:ok, map} when is_map(map) -> {:ok, map}
      {:ok, _} -> {:error, "payload must be a JSON object"}
      {:error, err} -> {:error, "invalid JSON: #{Exception.message(err)}"}
    end
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp format_origin(%{"type" => "channel", "channel" => ch, "chat_id" => cid}) do
    "channel(#{ch}/#{cid})"
  end

  defp format_origin(%{"type" => type} = m) do
    detail = Map.drop(m, ["type"]) |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
    "#{type}(#{detail})"
  end

  defp format_origin(other), do: inspect(other)
end
