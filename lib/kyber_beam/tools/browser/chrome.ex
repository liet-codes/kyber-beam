defmodule Kyber.Tools.Browser.Chrome do
  @moduledoc """
  Chrome launcher and CDP endpoint discovery.

  Checks if Chrome is running with `--remote-debugging-port=9222` and
  launches it if not. Returns the WebSocket debug URL for connecting
  the CDP client.
  """

  require Logger

  @debug_port 9222
  @launch_timeout_ms 5_000
  @poll_interval_ms 250

  @doc """
  Ensure Chrome is running with remote debugging enabled.
  Returns `{:ok, ws_url}` with the WebSocket URL for the first page target,
  or `{:error, reason}` if Chrome can't be reached.
  """
  @spec ensure_running() :: {:ok, String.t()} | {:error, String.t()}
  def ensure_running do
    case get_debug_ws_url() do
      {:ok, ws_url} ->
        {:ok, ws_url}

      {:error, _} ->
        Logger.info("[Chrome] Launching Chrome with remote debugging on port #{@debug_port}")
        launch_chrome()

        case wait_for_debug_port(@launch_timeout_ms) do
          :ok -> get_debug_ws_url()
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @doc """
  Get the WebSocket debug URL for the first page target.
  Returns `{:ok, ws_url}` or `{:error, reason}`.
  """
  @spec get_debug_ws_url() :: {:ok, String.t()} | {:error, String.t()}
  def get_debug_ws_url do
    url = "http://localhost:#{@debug_port}/json"

    case Req.get(url, connect_options: [timeout: 2_000], receive_timeout: 2_000) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        # Find the first "page" type target
        case Enum.find(body, fn t -> t["type"] == "page" end) do
          %{"webSocketDebuggerUrl" => ws_url} when is_binary(ws_url) ->
            {:ok, ws_url}

          nil ->
            # No page targets — try to get any target
            case List.first(body) do
              %{"webSocketDebuggerUrl" => ws_url} when is_binary(ws_url) ->
                {:ok, ws_url}

              _ ->
                {:error, "No targets with webSocketDebuggerUrl found"}
            end
        end

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # Body came as string, try to parse
        case Jason.decode(body) do
          {:ok, targets} when is_list(targets) ->
            case Enum.find(targets, fn t -> t["type"] == "page" end) do
              %{"webSocketDebuggerUrl" => ws_url} -> {:ok, ws_url}
              _ -> {:error, "No page targets found"}
            end

          _ ->
            {:error, "Unexpected response format from Chrome debug port"}
        end

      {:ok, %{status: status}} ->
        {:error, "Chrome debug port returned HTTP #{status}"}

      {:error, %{reason: :econnrefused}} ->
        {:error, "Chrome not running with remote debugging (port #{@debug_port})"}

      {:error, reason} ->
        {:error, "Failed to connect to Chrome debug port: #{inspect(reason)}"}
    end
  rescue
    e -> {:error, "Chrome detection failed: #{Exception.message(e)}"}
  end

  @doc """
  Check if Chrome debug port is accessible.
  """
  @spec debug_port_available?() :: boolean()
  def debug_port_available? do
    case Req.get("http://localhost:#{@debug_port}/json/version",
           connect_options: [timeout: 1_000],
           receive_timeout: 1_000
         ) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  # ── Private ────────────────────────────────────────────────────────────

  defp launch_chrome do
    # macOS: use `open` to launch Chrome with remote debugging args
    System.cmd("open", [
      "-a", "Google Chrome",
      "--args",
      "--remote-debugging-port=#{@debug_port}"
    ])
  end

  defp wait_for_debug_port(remaining_ms) when remaining_ms <= 0 do
    {:error, "Timed out waiting for Chrome debug port (#{@launch_timeout_ms}ms)"}
  end

  defp wait_for_debug_port(remaining_ms) do
    if debug_port_available?() do
      :ok
    else
      Process.sleep(@poll_interval_ms)
      wait_for_debug_port(remaining_ms - @poll_interval_ms)
    end
  end
end
