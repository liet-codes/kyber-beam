defmodule Kyber.Plugin.LLM.ApiClient do
  @moduledoc """
  HTTP client for the Anthropic Messages API.

  Handles auth detection, header building, request body construction,
  streaming vs sync dispatch, and retry/backoff logic.
  """

  require Logger

  @anthropic_url "https://api.anthropic.com/v1/messages"
  @default_model "claude-sonnet-4-20250514"
  @default_max_tokens 16_384
  @max_retries 3

  defp configured_model do
    Kyber.Config.get(:model, @default_model)
  end

  # ── Auth ──────────────────────────────────────────────────────────────────

  @doc "Detect whether a token is OAuth or API key based on prefix."
  @spec detect_auth_type(String.t()) :: :oauth | :api_key
  def detect_auth_type("sk-ant-oat" <> _), do: :oauth
  def detect_auth_type("sk-ant-api" <> _), do: :api_key
  def detect_auth_type(_), do: :api_key

  @doc "Load auth configuration from auth-profiles.json."
  @spec load_auth_config(String.t()) :: {:ok, map()} | {:error, term()}
  def load_auth_config(path) do
    expanded = Path.expand(path)

    with {:ok, raw} <- File.read(expanded),
         {:ok, data} <- Jason.decode(raw) do
      token = extract_token(data)

      if token do
        auth_type = detect_auth_type(token)
        {:ok, %{token: token, type: auth_type}}
      else
        {:error, :no_token_found}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Build the HTTP request headers for a given auth config."
  @spec build_headers(map()) :: [{String.t(), String.t()}]
  def build_headers(%{type: :oauth, token: token}) do
    [
      {"Authorization", "Bearer #{token}"},
      {"anthropic-version", "2023-06-01"},
      {"anthropic-beta",
       "claude-code-20250219,oauth-2025-04-20,fine-grained-tool-streaming-2025-05-14"},
      {"user-agent", "claude-cli/2.1.62"},
      {"x-app", "cli"},
      {"content-type", "application/json"}
    ]
  end

  def build_headers(%{type: :api_key, token: token}) do
    [
      {"x-api-key", token},
      {"anthropic-version", "2023-06-01"},
      {"content-type", "application/json"}
    ]
  end

  # ── Computer Use Beta ───────────────────────────────────────────────────

  @computer_use_beta_header_new "computer-use-2025-11-24"
  @computer_use_beta_header_legacy "computer-use-2025-01-24"

  # Models that use the newer computer_20251124 tool type
  @new_computer_use_models ["claude-opus-4-6", "claude-sonnet-4-6", "claude-opus-4-5"]

  @doc """
  Check if a list of tools includes any Anthropic computer use tool definitions
  (identified by type starting with "computer_").
  """
  @spec has_computer_use_tools?(list()) :: boolean()
  def has_computer_use_tools?(tools) when is_list(tools) do
    Enum.any?(tools, fn
      %{"type" => "computer_" <> _} -> true
      _ -> false
    end)
  end

  def has_computer_use_tools?(_), do: false

  @doc """
  Return the appropriate computer use beta header value for the given model.
  """
  @spec computer_use_beta_for_model(String.t()) :: String.t()
  def computer_use_beta_for_model(model) do
    if Enum.any?(@new_computer_use_models, &String.starts_with?(model, &1)) do
      @computer_use_beta_header_new
    else
      @computer_use_beta_header_legacy
    end
  end

  @doc """
  Return the appropriate computer use tool type for the given model.
  """
  @spec computer_use_tool_type(String.t()) :: String.t()
  def computer_use_tool_type(model) do
    if Enum.any?(@new_computer_use_models, &String.starts_with?(model, &1)) do
      "computer_20251124"
    else
      "computer_20250124"
    end
  end

  @doc """
  Add the computer use beta header to headers if computer use tools are present.
  """
  @spec maybe_add_computer_use_header([{String.t(), String.t()}], list(), String.t()) ::
          [{String.t(), String.t()}]
  def maybe_add_computer_use_header(headers, tools, model) do
    if has_computer_use_tools?(tools) do
      beta_value = computer_use_beta_for_model(model)

      # Check if there's already an anthropic-beta header and append to it
      case List.keyfind(headers, "anthropic-beta", 0) do
        {"anthropic-beta", existing} ->
          updated = existing <> "," <> beta_value
          List.keyreplace(headers, "anthropic-beta", 0, {"anthropic-beta", updated})

        nil ->
          [{"anthropic-beta", beta_value} | headers]
      end
    else
      headers
    end
  end

  # ── API calls ─────────────────────────────────────────────────────────────

  @doc """
  Call the Anthropic Messages API (sync path).

  Returns `{:ok, response_body}` or `{:error, %{error: msg, status: code}}`.
  """
  @spec call_api(map(), map()) :: {:ok, map()} | {:error, map()}
  def call_api(auth_config, params) do
    headers = build_headers(auth_config)
    body = build_api_body(auth_config, params)
    tools = body["tools"] || []
    model = body["model"] || @default_model
    headers = maybe_add_computer_use_header(headers, tools, model)

    system_info =
      case body["system"] do
        list when is_list(list) -> "yes (#{length(list)} blocks)"
        str when is_binary(str) -> "yes (#{String.length(str)} chars)"
        _ -> "no"
      end

    tools_info =
      case body["tools"] do
        tools when is_list(tools) -> "#{length(tools)} tools"
        _ -> "none"
      end

    Logger.info(
      "[Kyber.Plugin.LLM] calling API: model=#{body["model"]}, " <>
        "messages=#{length(body["messages"] || [])}, system=#{system_info}, tools=#{tools_info}"
    )

    call_api_with_retry(@anthropic_url, headers, body)
  end

  @doc """
  Call the API with streaming if enabled, falling back to sync on failure.

  Returns same format as `call_api/2`: `{:ok, response}` or `{:error, ...}`.
  """
  def call_api_maybe_stream(auth_config, params, core, origin, parent_id) do
    if Kyber.Config.get(:llm_streaming, true) do
      do_streaming_call(auth_config, params, core, origin, parent_id)
    else
      call_api(auth_config, params)
    end
  end

  # ── Content extraction ────────────────────────────────────────────────────

  @doc "Extract text content from an Anthropic API response."
  def extract_content(%{"content" => [%{"text" => text} | _]}), do: text

  def extract_content(%{"content" => content}) when is_list(content) do
    content
    |> Enum.filter(&is_map/1)
    |> Enum.map_join("\n", &Map.get(&1, "text", ""))
  end

  def extract_content(_), do: ""

  @doc "Format response text with a collapsible thinking/reasoning spoiler block."
  def format_with_reasoning(text, nil), do: text
  def format_with_reasoning(text, ""), do: text

  def format_with_reasoning(text, thinking) do
    thinking_block =
      thinking
      |> String.split("\n")
      |> Enum.map(&("> " <> &1))
      |> Enum.join("\n")

    "||🧠 **Reasoning**\n#{thinking_block}||\n\n#{text}"
  end

  @doc "Return the configured model name."
  def model, do: configured_model()

  @doc "Return the default max tokens."
  def default_max_tokens, do: @default_max_tokens

  # ── Private: Streaming ────────────────────────────────────────────────────

  # Overall hard timeout for a streaming call (covers the entire stream, not per-chunk)
  @streaming_overall_timeout_ms 90_000

  # Throttle Discord streaming preview edits to at most once per 2 seconds
  @streaming_preview_throttle_ms 2_000

  # Process-dict keys used inside the streaming Task
  @streaming_discord_msg_key :__kyber_streaming_discord_msg__
  @streaming_discord_last_edit_key :__kyber_streaming_discord_last_edit__

  defp do_streaming_call(auth_config, params, core, origin, parent_id) do
    alias Kyber.Plugin.LLM.ToolLoop

    headers = build_headers(auth_config)
    body = build_api_body(auth_config, params)

    # Add computer use beta header if needed
    tools = body["tools"] || []
    model = body["model"] || @default_model
    headers = maybe_add_computer_use_header(headers, tools, model)

    # Enable extended thinking if configured.
    # IMPORTANT: Disable thinking when computer_use tools are present —
    # Anthropic's API returns stop_reason=tool_use but with empty tool blocks
    # when thinking is enabled alongside computer_use, causing silent failures.
    has_computer_use = Enum.any?(tools, fn t ->
      (t["name"] || "") in ["computer", "computer_use"]
    end)

    body =
      case {Kyber.Config.get(:llm_thinking, true), has_computer_use} do
        {true, false} ->
          budget = Kyber.Config.get(:thinking_budget_tokens, 10_000)
          current_max = body["max_tokens"]
          new_max = max(current_max, budget + @default_max_tokens)

          body
          |> Map.put("thinking", %{"type" => "enabled", "budget_tokens" => budget})
          |> Map.put("max_tokens", new_max)
          |> Map.delete("temperature")

        {true, true} ->
          Logger.info("[LLM] computer_use tools detected — disabling thinking for compatibility")
          body

        _ ->
          body
      end

    # Refs used as keys in the task's process dict (defined outside so callback closure captures them)
    chunk_acc_ref = make_ref()
    thinking_acc_ref = make_ref()

    # Discord channel ID — only set for Discord origins (used for streaming preview)
    discord_channel_id =
      case origin do
        {:channel, "discord", cid, _} -> cid
        _ -> nil
      end

    # chat_id for stream_chunk delta payload (broader: includes human origins)
    chat_id =
      case origin do
        {:channel, _ch, cid, _sender} -> cid
        {:human, user_id} -> user_id
        _ -> nil
      end

    discord_token = get_discord_token()

    callback = fn
      {:text_chunk, text} ->
        new_text = Process.get(chunk_acc_ref, "") <> text
        Process.put(chunk_acc_ref, new_text)

        if rem(String.length(new_text), 100) < String.length(text) do
          stream_delta =
            Kyber.Delta.new(
              "llm.stream_chunk",
              %{"text" => new_text, "chat_id" => chat_id},
              origin,
              parent_id
            )

          ToolLoop.safe_emit(core, stream_delta)

          # Progressive Discord update (throttled)
          if discord_channel_id && discord_token do
            update_streaming_preview(discord_token, discord_channel_id, new_text)
          end
        end

      {:thinking_chunk, text} ->
        new_thinking = Process.get(thinking_acc_ref, "") <> text
        Process.put(thinking_acc_ref, new_thinking)

      {:done, _stop_reason} ->
        :ok

      _ ->
        :ok
    end

    # Wrap in Task.async so we can enforce a hard overall timeout (Issue 2).
    # The callback runs inside the task; streaming message ID is returned via
    # the task's return value so the parent can thread it through to the final
    # send_message effect (Issue 1).
    task =
      Task.async(fn ->
        # Initialize accumulators in the task's process dict
        Process.put(chunk_acc_ref, "")
        Process.put(thinking_acc_ref, "")

        result = Kyber.Plugin.LLM.Streamer.stream_request(@anthropic_url, body, headers, callback)

        # Capture streaming Discord message ID (if any) before task exits
        streaming_msg_id = Process.get(@streaming_discord_msg_key)
        {result, streaming_msg_id}
      end)

    Logger.info("[LLM] waiting for streaming task (timeout=#{@streaming_overall_timeout_ms}ms)")

    yield_result = Task.yield(task, @streaming_overall_timeout_ms)

    result =
      case yield_result do
        nil ->
          Logger.warning("[LLM] Task.yield returned nil, shutting down task")
          Task.shutdown(task)

        other ->
          other
      end

    Logger.info("[LLM] streaming task result type: #{inspect(elem_safe(result))}")

    case result do
      {:ok, {{:ok, response}, streaming_msg_id}} ->
        stop_reason = response["stop_reason"]
        Logger.info("[LLM] streaming complete, stop_reason=#{stop_reason}")

        # For tool_use intermediate calls, the streaming preview is a dead-end
        # (the final send comes from a later LLM call). Delete the orphaned
        # preview so users don't see a dangling ⏳ message.
        response_with_id =
          cond do
            streaming_msg_id && stop_reason == "tool_use" && discord_channel_id && discord_token ->
              Task.start(fn ->
                Kyber.Plugin.Discord.delete_message(discord_token, discord_channel_id, streaming_msg_id)
              end)
              response

            is_binary(streaming_msg_id) ->
              # end_turn with a preview → pass ID so final send edits it
              Map.put(response, "_streaming_message_id", streaming_msg_id)

            true ->
              response
          end

        thinking = Kyber.Plugin.LLM.Streamer.extract_thinking(response)

        if thinking do
          text_content = extract_content(response)
          formatted = format_with_reasoning(text_content, thinking)
          new_content = [%{"type" => "text", "text" => formatted}]
          {:ok, Map.put(response_with_id, "content", new_content)}
        else
          {:ok, response_with_id}
        end

      {:ok, {{:error, reason}, _streaming_msg_id}} ->
        Logger.warning("[LLM] streaming failed: #{inspect(reason)}, falling back to sync")
        call_api(auth_config, params)

      {:exit, reason} ->
        # Task crashed — log it clearly
        Logger.error("[LLM] streaming task crashed: #{inspect(reason)}")
        {:error, "streaming task crashed: #{inspect(reason)}"}

      nil ->
        # Hard timeout — do NOT fall back to sync (it would also hang)
        Logger.warning("[LLM] streaming timed out after #{@streaming_overall_timeout_ms}ms — aborting")
        {:error, :timeout}
    end
  end

  defp elem_safe(nil), do: :timeout
  defp elem_safe({:ok, _}), do: :ok
  defp elem_safe({:exit, _}), do: :exit
  defp elem_safe(other), do: other

  # Send or edit the Discord streaming preview message.
  # Called from within the streaming Task — uses the task's process dict.
  defp update_streaming_preview(discord_token, channel_id, text) do
    preview = String.slice(text, 0, 1900) <> " ⏳"
    now_ms = System.monotonic_time(:millisecond)

    case Process.get(@streaming_discord_msg_key) do
      nil ->
        # First chunk — create an initial preview message
        case Kyber.Plugin.Discord.post_message_with_id(discord_token, channel_id, preview) do
          {:ok, msg_id} ->
            Process.put(@streaming_discord_msg_key, msg_id)
            Process.put(@streaming_discord_last_edit_key, now_ms)

          {:error, reason} ->
            Logger.debug("[LLM] streaming preview create failed: #{inspect(reason)}")
        end

      msg_id ->
        # Subsequent chunks — throttle edits to once per 2 seconds
        last_edit = Process.get(@streaming_discord_last_edit_key, 0)

        if now_ms - last_edit >= @streaming_preview_throttle_ms do
          case Kyber.Plugin.Discord.edit_message(discord_token, channel_id, msg_id, preview) do
            :ok ->
              Process.put(@streaming_discord_last_edit_key, now_ms)

            {:error, reason} ->
              Logger.debug("[LLM] streaming preview edit failed: #{inspect(reason)}")
          end
        end
    end
  end

  # Look up the Discord bot token the same way the Discord plugin does.
  defp get_discord_token do
    System.get_env("DISCORD_BOT_TOKEN") ||
      Application.get_env(:kyber_beam, :discord_bot_token)
  end

  # ── Private: Body building (shared between sync and streaming) ────────────

  defp build_api_body(auth_config, params) do
    body = %{
      "model" => params["model"] || @default_model,
      "max_tokens" => params["max_tokens"] || @default_max_tokens,
      "messages" => params["messages"] || []
    }

    body =
      case params["tools"] do
        [_ | _] = tools -> Map.put(body, "tools", tools)
        _ -> body
      end

    case {auth_config.type, params["system"]} do
      {:oauth, system} when is_binary(system) ->
        Map.put(body, "system", [
          %{"type" => "text", "text" => "You are Claude Code, Anthropic's official CLI for Claude."},
          %{"type" => "text", "text" => system}
        ])

      {:oauth, nil} ->
        Map.put(body, "system", [
          %{"type" => "text", "text" => "You are Claude Code, Anthropic's official CLI for Claude."}
        ])

      {_, system} when is_binary(system) ->
        Map.put(body, "system", system)

      _ ->
        body
    end
  end

  # ── Private: Retry logic ──────────────────────────────────────────────────

  defp call_api_with_retry(url, headers, body, retries_left \\ @max_retries) do
    case Req.post(url, headers: headers, json: body, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: 401, body: resp_body}} ->
        Logger.error("""
        [Kyber.Plugin.LLM] ⛔ Authentication failed (401).
        OAuth token expired or revoked — re-authenticate by running `claude` in a terminal.
        Response: #{inspect(resp_body)}
        """)

        error_msg = get_in(resp_body, ["error", "message"]) || "OAuth token expired — re-authenticate with `claude` CLI"
        {:error, %{error: error_msg, status: 401}}

      {:ok, %{status: 429, headers: resp_headers}} when retries_left > 0 ->
        delay = parse_retry_after(resp_headers, 5_000)
        Logger.warning("[Kyber.Plugin.LLM] rate limited (429), retrying after #{delay}ms")
        Process.sleep(delay)
        call_api_with_retry(url, headers, body, retries_left - 1)

      {:ok, %{status: 429, body: resp_body}} ->
        Logger.error(
          "[Kyber.Plugin.LLM] rate limited (429), no retries left: #{inspect(resp_body)}"
        )

        error_msg = get_in(resp_body, ["error", "message"]) || inspect(resp_body)
        {:error, %{error: error_msg, status: 429}}

      {:ok, %{status: status}} when status >= 500 and retries_left > 0 ->
        backoff = backoff_ms(@max_retries - retries_left)

        Logger.warning(
          "[Kyber.Plugin.LLM] API error #{status}, retrying in #{backoff}ms (#{retries_left} left)"
        )

        Process.sleep(backoff)
        call_api_with_retry(url, headers, body, retries_left - 1)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[Kyber.Plugin.LLM] API error #{status}: #{inspect(resp_body)}")
        error_msg = get_in(resp_body, ["error", "message"]) || inspect(resp_body)
        {:error, %{error: error_msg, status: status}}

      {:error, reason} when retries_left > 0 ->
        backoff = backoff_ms(@max_retries - retries_left)

        Logger.warning(
          "[Kyber.Plugin.LLM] network error #{inspect(reason)}, retrying in #{backoff}ms (#{retries_left} left)"
        )

        Process.sleep(backoff)
        call_api_with_retry(url, headers, body, retries_left - 1)

      {:error, reason} ->
        {:error, %{error: inspect(reason), status: 0}}
    end
  end

  defp backoff_ms(attempt) do
    :math.pow(2, attempt) |> round() |> Kernel.*(1_000)
  end

  defp parse_retry_after(headers, default_ms) when is_list(headers) do
    case find_header(headers, "retry-after") do
      nil -> default_ms
      val -> parse_retry_after_value(val, default_ms)
    end
  end

  defp parse_retry_after(headers, default_ms) when is_map(headers) do
    val = Map.get(headers, "retry-after") || Map.get(headers, "Retry-After")
    parse_retry_after_value(val, default_ms)
  end

  defp parse_retry_after(_, default_ms), do: default_ms

  defp parse_retry_after_value(nil, default_ms), do: default_ms

  defp parse_retry_after_value(val, default_ms) when is_binary(val) do
    case Integer.parse(val) do
      {secs, _} when secs > 0 -> secs * 1_000
      _ -> default_ms
    end
  end

  defp parse_retry_after_value(val, _default_ms) when is_integer(val) and val > 0,
    do: val * 1_000

  defp parse_retry_after_value(_, default_ms), do: default_ms

  defp find_header(headers, name) when is_list(headers) do
    Enum.find_value(headers, fn
      {k, v} when is_binary(k) ->
        if String.downcase(k) == name, do: to_string(v)

      _ ->
        nil
    end)
  end

  # ── Private: Token extraction ─────────────────────────────────────────────

  defp extract_token(%{"claudeAiOauth" => %{"accessToken" => token}}) when is_binary(token),
    do: token

  defp extract_token(%{"oauthToken" => token}) when is_binary(token), do: token
  defp extract_token(%{"apiKey" => token}) when is_binary(token), do: token
  defp extract_token(%{"token" => token}) when is_binary(token), do: token

  defp extract_token(data) when is_map(data) do
    Enum.find_value(data, fn {_k, v} ->
      case v do
        %{} ->
          extract_token(v)

        str when is_binary(str) and byte_size(str) > 20 ->
          if String.starts_with?(str, "sk-ant-"), do: str, else: nil

        _ ->
          nil
      end
    end)
  end

  defp extract_token(_), do: nil
end
