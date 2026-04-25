defmodule Kyber.Plugin.LLM.OpenRouterClient do
  @moduledoc """
  HTTP client for OpenRouter API (OpenAI-compatible format).

  Supports Nous Research Hermes models and other OpenRouter-hosted LLMs.
  Uses OpenAI-style function calling (different from Anthropic's tool use).
  """

  require Logger

  @openrouter_url "https://openrouter.ai/api/v1/chat/completions"
  @default_model "nousresearch/hermes-3-llama-3.1-405b:free"
  @default_max_tokens 16_384
  @max_retries 3

  # Hermes models that support tool calling well
  @hermes_models [
    "nousresearch/hermes-3-llama-3.1-405b:free",
    "nousresearch/hermes-3-llama-3.1-70b",
    "nousresearch/hermes-4-llama-3.1-405b",
    "nousresearch/hermes-4-llama-3.1-70b"
  ]

  defp configured_model do
    Kyber.Config.get(:model, @default_model)
  end

  @doc "Check if a model is a Hermes model (for tool calling compatibility)."
  @spec hermes_model?(String.t()) :: boolean()
  def hermes_model?(model) do
    model in @hermes_models || String.starts_with?(model, "nousresearch/hermes-")
  end

  # ── Auth ──────────────────────────────────────────────────────────────────

  @doc "Detect whether a token is an OpenRouter key based on prefix."
  @spec detect_auth_type(String.t()) :: :openrouter | :unknown
  def detect_auth_type("sk-or-v1-" <> _), do: :openrouter
  def detect_auth_type("sk-or-" <> _), do: :openrouter
  def detect_auth_type(_), do: :unknown

  @doc "Build the HTTP request headers for OpenRouter."
  @spec build_headers(String.t()) :: [{String.t(), String.t()}]
  def build_headers(token) do
    [
      {"Authorization", "Bearer #{token}"},
      {"Content-Type", "application/json"},
      {"HTTP-Referer", "https://kyber-beam.local"},
      {"X-Title", "Kyber-Beam"}
    ]
  end

  # ── API calls ─────────────────────────────────────────────────────────────

  @doc """
  Call the OpenRouter API (sync path).

  Returns `{:ok, response_body}` or `{:error, %{error: msg, status: code}}`.
  """
  @spec call_api(String.t(), map()) :: {:ok, map()} | {:error, map()}
  def call_api(token, params) do
    headers = build_headers(token)
    body = build_api_body(params)

    tools = body[:tools] || body["tools"] || []
    model = body[:model] || body["model"] || @default_model

    Logger.info(
      "[Kyber.Plugin.LLM.OpenRouter] calling API: model=#{model}, " <>
        "messages=#{length(body[:messages] || body["messages"] || [])}, tools=#{length(tools)}"
    )

    call_api_with_retry(@openrouter_url, headers, body)
  end

  @doc """
  Call the API with streaming if enabled.
  """
  def call_api_maybe_stream(token, params, core, origin, parent_id) do
    if Kyber.Config.get(:llm_streaming, true) do
      do_streaming_call(token, params, core, origin, parent_id)
    else
      call_api(token, params)
    end
  end

  # ── Content extraction ────────────────────────────────────────────────────

  @doc "Extract text content from an OpenRouter API response."
  def extract_content(%{"choices" => [%{"message" => %{"content" => content}} | _]}) do
    content || ""
  end

  def extract_content(%{"choices" => choices}) when is_list(choices) do
    choices
    |> Enum.map(fn choice -> get_in(choice, ["message", "content"]) || "" end)
    |> Enum.join("\n")
  end

  def extract_content(_), do: ""

  @doc "Extract tool calls from an OpenRouter API response."
  def extract_tool_calls(%{"choices" => [%{"message" => %{"tool_calls" => calls}} | _]}) do
    calls || []
  end

  def extract_tool_calls(%{"choices" => choices}) when is_list(choices) do
    choices
    |> Enum.flat_map(fn choice -> get_in(choice, ["message", "tool_calls"]) || [] end)
  end

  def extract_tool_calls(_), do: []

  @doc "Convert OpenAI-style tool calls to Anthropic-style for compatibility."
  def convert_tool_calls(openai_calls) do
    openai_calls
    |> Enum.map(fn call ->
      %{
        "type" => "tool_use",
        "id" => call["id"] || "call_#{System.unique_integer([:positive])}",
        "name" => call["function"]["name"],
        "input" => parse_tool_input(call["function"]["arguments"])
      }
    end)
  end

  defp parse_tool_input(nil), do: %{}
  defp parse_tool_input("") , do: %{}
  defp parse_tool_input(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, parsed} -> parsed
      {:error, _} -> %{}
    end
  end
  defp parse_tool_input(map) when is_map(map), do: map

  @doc "Return the configured model name."
  def model, do: configured_model()

  @doc "Return the default max tokens."
  def default_max_tokens, do: @default_max_tokens

  # ── Private: Streaming ────────────────────────────────────────────────────

  @streaming_overall_timeout_ms 90_000
  @streaming_preview_throttle_ms 2_000

  @streaming_discord_msg_key :__kyber_openrouter_streaming_discord_msg__
  @streaming_discord_last_edit_key :__kyber_openrouter_streaming_discord_last_edit__

  defp do_streaming_call(token, params, core, origin, parent_id) do
    alias Kyber.Plugin.LLM.ToolLoop

    headers = build_headers(token)
    body = build_api_body(params) |> Map.put(:stream, true)

    tools = body[:tools] || body["tools"] || []
    model = body[:model] || body["model"] || @default_model

    discord_channel_id =
      case origin do
        {:channel, "discord", cid, _} -> cid
        _ -> nil
      end

    chat_id =
      case origin do
        {:channel, _ch, cid, _sender} -> cid
        {:human, user_id} -> user_id
        _ -> nil
      end

    discord_token = get_discord_token()

    chunk_acc_ref = make_ref()

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

          if discord_channel_id && discord_token do
            update_streaming_preview(discord_token, discord_channel_id, new_text)
          end
        end

      {:done, _reason} ->
        :ok

      _ ->
        :ok
    end

    task =
      Task.async(fn ->
        Process.put(chunk_acc_ref, "")

        result = stream_request(@openrouter_url, body, headers, callback)

        streaming_msg_id = Process.get(@streaming_discord_msg_key)
        {result, streaming_msg_id}
      end)

    Logger.info("[LLM.OpenRouter] waiting for streaming task")

    yield_result = Task.yield(task, @streaming_overall_timeout_ms)

    result =
      case yield_result do
        nil ->
          Logger.warning("[LLM.OpenRouter] streaming timed out")
          Task.shutdown(task)
          {:error, :timeout}

        other ->
          other
      end

    case result do
      {:ok, {{:ok, response}, streaming_msg_id}} ->
        response_with_id =
          if is_binary(streaming_msg_id) do
            Map.put(response, "_streaming_message_id", streaming_msg_id)
          else
            response
          end

        {:ok, response_with_id}

      {:ok, {{:error, reason}, _}} ->
        Logger.warning("[LLM.OpenRouter] streaming failed: #{inspect(reason)}")
        call_api(token, params)

      {:exit, reason} ->
        Logger.error("[LLM.OpenRouter] streaming task crashed: #{inspect(reason)}")
        {:error, "streaming task crashed: #{inspect(reason)}"}

      {:error, :timeout} ->
        {:error, :timeout}
    end
  end

  defp stream_request(url, body, headers, callback) do
    # Simple streaming implementation for OpenRouter
    # Uses Finch or Req with stream option
    
    req_body = Jason.encode!(body)
    
    case Req.post(url, 
      headers: headers, 
      body: req_body, 
      receive_timeout: 60_000,
      into: fn {:data, data}, {req, resp} ->
        # Process SSE data
        lines = String.split(data, "\n")
        
        Enum.each(lines, fn line ->
          case String.trim(line) do
            "data: " <> json ->
              case Jason.decode(json) do
                {:ok, %{"choices" => [%{"delta" => %{"content" => content}} | _]}} when is_binary(content) ->
                  callback.({:text_chunk, content})
                  
                {:ok, %{"choices" => [%{"finish_reason" => reason} | _]}} when not is_nil(reason) ->
                  callback.({:done, reason})
                  
                _ ->
                  :ok
              end
              
            _ ->
              :ok
          end
        end)
        
        {:cont, {req, resp}}
      end
    ) do
      {:ok, %{status: 200, body: body}} ->
        # For streaming, body might be empty or contain final response
        {:ok, body}
        
      {:ok, %{status: status, body: body}} ->
        Logger.error("[LLM.OpenRouter] API error #{status}: #{inspect(body)}")
        {:error, %{error: "API error #{status}", status: status}}
        
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp update_streaming_preview(discord_token, channel_id, text) do
    preview = String.slice(text, 0, 1900) <> " ⏳"
    now_ms = System.monotonic_time(:millisecond)

    case Process.get(@streaming_discord_msg_key) do
      nil ->
        case Kyber.Plugin.Discord.post_message_with_id(discord_token, channel_id, preview) do
          {:ok, msg_id} ->
            Process.put(@streaming_discord_msg_key, msg_id)
            Process.put(@streaming_discord_last_edit_key, now_ms)

          {:error, reason} ->
            Logger.debug("[LLM.OpenRouter] streaming preview create failed: #{inspect(reason)}")
        end

      msg_id ->
        last_edit = Process.get(@streaming_discord_last_edit_key, 0)

        if now_ms - last_edit >= @streaming_preview_throttle_ms do
          case Kyber.Plugin.Discord.edit_message(discord_token, channel_id, msg_id, preview) do
            :ok ->
              Process.put(@streaming_discord_last_edit_key, now_ms)

            {:error, reason} ->
              Logger.debug("[LLM.OpenRouter] streaming preview edit failed: #{inspect(reason)}")
          end
        end
    end
  end

  defp get_discord_token do
    System.get_env("DISCORD_BOT_TOKEN") ||
      Application.get_env(:kyber_beam, :discord_bot_token)
  end

  # ── Private: Body building ────────────────────────────────────────────────

  defp build_api_body(params) do
    model = params["model"] || params[:model] || configured_model()
    
    body = %{
      model: model,
      max_tokens: params["max_tokens"] || params[:max_tokens] || @default_max_tokens,
      messages: convert_messages(params["messages"] || params[:messages] || [])
    }

    # Add tools if present (OpenAI format)
    body =
      case params["tools"] || params[:tools] do
        [_ | _] = tools -> 
          converted_tools = convert_tools_to_openai(tools)
          Map.put(body, :tools, converted_tools)
        _ -> 
          body
      end

    # Add system message if present
    body =
      case params["system"] || params[:system] do
        system when is_binary(system) and system != "" ->
          # Prepend system message to messages list
          messages = [%{role: "system", content: system} | body.messages]
          %{body | messages: messages}
        _ ->
          body
      end

    body
  end

  # Convert Anthropic-style messages to OpenAI format
  defp convert_messages(messages) do
    messages
    |> Enum.map(fn msg ->
      role = msg["role"] || msg[:role] || "user"
      content = msg["content"] || msg[:content] || ""
      
      # Handle content that might be a list (Anthropic format)
      content_text =
        case content do
          list when is_list(list) ->
            list
            |> Enum.map(fn
              %{"type" => "text", "text" => text} -> text
              %{type: "text", text: text} -> text
              %{"text" => text} -> text
              %{text: text} -> text
              text when is_binary(text) -> text
              _ -> ""
            end)
            |> Enum.join("\n")
            
          text when is_binary(text) ->
            text
            
          _ ->
            ""
        end

      # Map Anthropic roles to OpenAI roles
      openai_role =
        case role do
          "user" -> "user"
          "assistant" -> "assistant"
          :user -> "user"
          :assistant -> "assistant"
          _ -> "user"
        end

      %{role: openai_role, content: content_text}
    end)
  end

  # Convert Anthropic-style tools to OpenAI format
  defp convert_tools_to_openai(tools) do
    tools
    |> Enum.map(fn tool ->
      name = tool["name"] || tool[:name] || "unnamed_tool"
      description = tool["description"] || tool[:description] || ""
      input_schema = tool["input_schema"] || tool[:input_schema] || tool["parameters"] || tool[:parameters] || %{}
      
      %{
        type: "function",
        function: %{
          name: name,
          description: description,
          parameters: input_schema
        }
      }
    end)
  end

  # ── Private: Retry logic ──────────────────────────────────────────────────

  defp call_api_with_retry(url, headers, body, retries_left \\ @max_retries) do
    req_body = Jason.encode!(body)
    
    case Req.post(url, headers: headers, body: req_body, receive_timeout: 60_000) do
      {:ok, %{status: 200, body: response}} ->
        {:ok, response}

      {:ok, %{status: 401, body: resp_body}} ->
        Logger.error("[Kyber.Plugin.LLM.OpenRouter] Authentication failed (401)")
        error_msg = get_in(resp_body, ["error", "message"]) || "Authentication failed"
        {:error, %{error: error_msg, status: 401}}

      {:ok, %{status: 429, headers: resp_headers}} when retries_left > 0 ->
        delay = parse_retry_after(resp_headers, 5_000)
        Logger.warning("[LLM.OpenRouter] rate limited (429), retrying after #{delay}ms")
        Process.sleep(delay)
        call_api_with_retry(url, headers, body, retries_left - 1)

      {:ok, %{status: 429, body: resp_body}} ->
        Logger.error("[LLM.OpenRouter] rate limited (429), no retries left")
        error_msg = get_in(resp_body, ["error", "message"]) || "Rate limited"
        {:error, %{error: error_msg, status: 429}}

      {:ok, %{status: status}} when status >= 500 and retries_left > 0 ->
        backoff = backoff_ms(@max_retries - retries_left)
        Logger.warning("[LLM.OpenRouter] API error #{status}, retrying in #{backoff}ms")
        Process.sleep(backoff)
        call_api_with_retry(url, headers, body, retries_left - 1)

      {:ok, %{status: status, body: resp_body}} ->
        Logger.error("[LLM.OpenRouter] API error #{status}: #{inspect(resp_body)}")
        error_msg = get_in(resp_body, ["error", "message"]) || "API error #{status}"
        {:error, %{error: error_msg, status: status}}

      {:error, reason} when retries_left > 0 ->
        backoff = backoff_ms(@max_retries - retries_left)
        Logger.warning("[LLM.OpenRouter] network error, retrying in #{backoff}ms")
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
    case List.keyfind(headers, "retry-after", 0) do
      {"retry-after", val} -> parse_retry_after_value(val, default_ms)
      _ -> default_ms
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
end
