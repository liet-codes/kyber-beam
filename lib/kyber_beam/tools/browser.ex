defmodule Kyber.Tools.Browser do
  @moduledoc """
  High-level browser control tool that translates LLM actions into
  CDP (Chrome DevTools Protocol) command sequences.

  Wraps `Kyber.Tools.Browser.CdpClient` with ergonomic functions:
  navigate, click, type, read, screenshot, evaluate, get_text.
  """

  alias Kyber.Tools.Browser.{CdpClient, Chrome}
  require Logger

  # Singleton CDP client — stored in a named process
  @client_name :kyber_browser_cdp

  @doc """
  Execute a browser action.

  Actions: "launch", "navigate", "click", "type", "read",
           "screenshot", "evaluate", "get_text"
  """
  @spec execute(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(action, params \\ %{})

  def execute("launch", _params) do
    case Chrome.ensure_running() do
      {:ok, ws_url} ->
        case ensure_client(ws_url) do
          {:ok, _pid} -> {:ok, "Chrome launched and CDP connected (#{ws_url})"}
          {:error, reason} -> {:error, "Chrome running but CDP connect failed: #{inspect(reason)}"}
        end

      {:error, reason} ->
        {:error, "Failed to launch Chrome: #{reason}"}
    end
  end

  def execute("navigate", %{"url" => url}) do
    with {:ok, client} <- get_or_connect_client(),
         {:ok, _} <- CdpClient.send_command(client, "Page.enable"),
         {:ok, result} <- CdpClient.send_command(client, "Page.navigate", %{"url" => url}) do
      frame_id = Map.get(result, "frameId", "unknown")

      # Wait briefly for page to start loading
      Process.sleep(500)

      {:ok, "Navigated to #{url} (frame: #{frame_id})"}
    else
      {:error, reason} -> {:error, "navigate failed: #{format_error(reason)}"}
    end
  end

  def execute("navigate", _params) do
    {:error, "navigate requires 'url' parameter"}
  end

  def execute("click", %{"selector" => selector}) do
    with {:ok, client} <- get_or_connect_client(),
         {:ok, coords} <- get_element_center(client, selector),
         {:ok, _} <- dispatch_click(client, coords) do
      {:ok, "Clicked element: #{selector}"}
    else
      {:error, reason} -> {:error, "click failed: #{format_error(reason)}"}
    end
  end

  def execute("click", _params) do
    {:error, "click requires 'selector' parameter"}
  end

  def execute("type", %{"selector" => selector, "text" => text}) do
    with {:ok, client} <- get_or_connect_client(),
         {:ok, coords} <- get_element_center(client, selector),
         {:ok, _} <- dispatch_click(client, coords),
         :ok <- dispatch_key_events(client, text) do
      {:ok, "Typed #{String.length(text)} chars into #{selector}"}
    else
      {:error, reason} -> {:error, "type failed: #{format_error(reason)}"}
    end
  end

  def execute("type", _params) do
    {:error, "type requires 'selector' and 'text' parameters"}
  end

  def execute("read", %{"selector" => selector}) do
    js = """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)});
      if (!el) return JSON.stringify({error: 'Element not found: #{selector}'});
      return JSON.stringify({
        tagName: el.tagName,
        text: el.innerText?.substring(0, 5000) || '',
        html: el.outerHTML?.substring(0, 5000) || '',
        value: el.value || null
      });
    })()
    """

    with {:ok, client} <- get_or_connect_client(),
         {:ok, result} <- CdpClient.send_command(client, "Runtime.evaluate", %{
           "expression" => js,
           "returnByValue" => true
         }) do
      value = get_in(result, ["result", "value"])

      case Jason.decode(value || "{}") do
        {:ok, %{"error" => error}} -> {:error, error}
        {:ok, data} ->
          text = data["text"] || ""
          tag = data["tagName"] || ""
          value_str = if data["value"], do: "\nValue: #{data["value"]}", else: ""
          {:ok, "<#{String.downcase(tag)}> #{text}#{value_str}"}

        {:error, _} ->
          {:ok, "#{value}"}
      end
    else
      {:error, reason} -> {:error, "read failed: #{format_error(reason)}"}
    end
  end

  def execute("read", _params) do
    {:error, "read requires 'selector' parameter"}
  end

  def execute("screenshot", _params) do
    with {:ok, client} <- get_or_connect_client(),
         {:ok, result} <- CdpClient.send_command(client, "Page.captureScreenshot", %{
           "format" => "png"
         }) do
      data = Map.get(result, "data", "")
      byte_size = byte_size(data)
      {:ok, "Screenshot captured (#{byte_size} bytes base64)\ndata:image/png;base64,#{data}"}
    else
      {:error, reason} -> {:error, "screenshot failed: #{format_error(reason)}"}
    end
  end

  def execute("evaluate", %{"javascript" => js}) do
    with {:ok, client} <- get_or_connect_client(),
         {:ok, result} <- CdpClient.send_command(client, "Runtime.evaluate", %{
           "expression" => js,
           "returnByValue" => true,
           "awaitPromise" => true
         }) do
      eval_result = get_in(result, ["result", "value"])
      type = get_in(result, ["result", "type"]) || "undefined"

      exception = get_in(result, ["exceptionDetails"])

      if exception do
        error_text = get_in(exception, ["exception", "description"]) ||
                     get_in(exception, ["text"]) ||
                     "JS evaluation error"
        {:error, error_text}
      else
        {:ok, "(#{type}) #{inspect(eval_result)}"}
      end
    else
      {:error, reason} -> {:error, "evaluate failed: #{format_error(reason)}"}
    end
  end

  def execute("evaluate", _params) do
    {:error, "evaluate requires 'javascript' parameter"}
  end

  def execute("get_text", _params) do
    execute("evaluate", %{
      "javascript" => "document.body.innerText.substring(0, 10000)"
    })
  end

  def execute(action, _params) do
    {:error, "Unknown browser action: #{action}. Valid: launch, navigate, click, type, read, screenshot, evaluate, get_text"}
  end

  # ── CDP Helpers ────────────────────────────────────────────────────────

  defp get_element_center(client, selector) do
    js = """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)});
      if (!el) return JSON.stringify({error: 'not_found'});
      const rect = el.getBoundingClientRect();
      return JSON.stringify({
        x: rect.x + rect.width / 2,
        y: rect.y + rect.height / 2
      });
    })()
    """

    case CdpClient.send_command(client, "Runtime.evaluate", %{
           "expression" => js,
           "returnByValue" => true
         }) do
      {:ok, result} ->
        value = get_in(result, ["result", "value"])

        case Jason.decode(value || "{}") do
          {:ok, %{"error" => "not_found"}} ->
            {:error, "Element not found: #{selector}"}

          {:ok, %{"x" => x, "y" => y}} ->
            {:ok, {x, y}}

          _ ->
            {:error, "Failed to get element coordinates"}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp dispatch_click(client, {x, y}) do
    with {:ok, _} <- CdpClient.send_command(client, "Input.dispatchMouseEvent", %{
           "type" => "mousePressed",
           "x" => x,
           "y" => y,
           "button" => "left",
           "clickCount" => 1
         }),
         {:ok, _} <- CdpClient.send_command(client, "Input.dispatchMouseEvent", %{
           "type" => "mouseReleased",
           "x" => x,
           "y" => y,
           "button" => "left",
           "clickCount" => 1
         }) do
      {:ok, :clicked}
    end
  end

  defp dispatch_key_events(client, text) do
    text
    |> String.graphemes()
    |> Enum.reduce_while(:ok, fn char, _acc ->
      case CdpClient.send_command(client, "Input.dispatchKeyEvent", %{
             "type" => "keyDown",
             "text" => char
           }) do
        {:ok, _} ->
          CdpClient.send_command(client, "Input.dispatchKeyEvent", %{
            "type" => "keyUp"
          })

          {:cont, :ok}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  # ── Client Management ─────────────────────────────────────────────────

  defp get_or_connect_client do
    case Process.whereis(@client_name) do
      nil ->
        case Chrome.get_debug_ws_url() do
          {:ok, ws_url} -> ensure_client(ws_url)
          {:error, reason} -> {:error, "Chrome not running: #{reason}. Use action 'launch' first."}
        end

      pid ->
        if Process.alive?(pid) do
          {:ok, pid}
        else
          Process.unregister(@client_name)
          get_or_connect_client()
        end
    end
  end

  defp ensure_client(ws_url) do
    # Kill old client if exists
    case Process.whereis(@client_name) do
      nil -> :ok
      old_pid ->
        try do
          Process.unregister(@client_name)
          CdpClient.disconnect(old_pid)
        rescue
          _ -> :ok
        catch
          _, _ -> :ok
        end
    end

    case CdpClient.start_link(ws_url: ws_url) do
      {:ok, pid} ->
        try do
          Process.register(pid, @client_name)
        rescue
          ArgumentError ->
            # Name already registered (race condition) — kill ours and use existing
            CdpClient.disconnect(pid)

            case Process.whereis(@client_name) do
              nil -> {:error, "Failed to register CDP client"}
              existing -> {:ok, existing}
            end
        end

        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp format_error(%{"message" => msg}), do: msg
  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
