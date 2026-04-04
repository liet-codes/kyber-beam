defmodule Kyber.Plugin.LLM.ToolLoop do
  @moduledoc """
  Multi-turn tool execution loop for the Anthropic API.

  Handles:
  - The iterative tool_use → tool_result → API call cycle (up to 10 iterations)
  - Tool result block building (text, image, error)
  - Image handling for vision (base64 encoding)
  - Delta emission for observability (llm.call, tool.call, tool.result)
  - Top-level request orchestration (handle_llm_call)
  """

  require Logger

  alias Kyber.Plugin.LLM.{ApiClient, PromptBuilder}

  @default_max_tokens 16_384

  # ── Public: Request handler ───────────────────────────────────────────────

  @doc """
  Handle an incoming :llm_call effect.

  Orchestrates the full request lifecycle:
  1. Load conversation history from session
  2. Build user message (with image attachments if present)
  3. Store user message in session
  4. Build system prompt
  5. Run the tool loop
  6. Store assistant response and emit result delta
  """
  def handle_llm_call(effect, core, session, auth_config) do
    payload = Map.get(effect, :payload, %{})
    origin = Map.get(effect, :origin)
    parent_id = Map.get(effect, :delta_id)

    chat_id = chat_id_from_origin(origin)

    # Get conversation history from session with token-budget trimming
    history =
      if chat_id && process_alive?(session) do
        raw_history =
          Kyber.Session.get_history(session, chat_id)
          |> Enum.map(fn delta ->
            role = Map.get(delta.payload, "role", "user")
            content = Map.get(delta.payload, "content", "")
            %{"role" => role, "content" => content}
          end)

        budget = Kyber.Config.get(:max_context_tokens, 180_000)

        {trimmed, dropped, est_tokens} =
          Kyber.TokenCounter.trim_to_budget(raw_history, budget: budget)

        if dropped > 0 do
          Logger.info(
            "[LLM] trimmed #{dropped} messages (estimated #{Float.round(est_tokens / 1_000, 1)}k tokens, budget #{Float.round(budget / 1_000, 1)}k)"
          )
        end

        trimmed
      else
        []
      end

    # Build current user message
    text = payload["text"] || ""
    attachments = payload["attachments"] || []
    content = PromptBuilder.build_user_content(text, attachments)

    # Store user message in session BEFORE API call
    if chat_id && process_alive?(session) do
      user_delta =
        Kyber.Delta.new(
          "session.user",
          %{"role" => "user", "content" => content},
          origin
        )

      Kyber.Session.add_message(session, chat_id, user_delta)
    end

    # Build messages list for the API call
    messages =
      if is_list(payload["messages"]) do
        payload["messages"]
      else
        history ++ [%{"role" => "user", "content" => content}]
      end

    # Load system prompt: explicit payload > vault knowledge context
    system_prompt = payload["system"] || PromptBuilder.build_system_prompt(chat_id)

    # Set channel context for tools that need it (e.g. send_file)
    case origin do
      {:channel, "discord", cid, _} ->
        Kyber.ToolExecutor.set_channel_context(cid)

      _ ->
        :ok
    end

    case auth_config do
      nil ->
        emit_error(core, "no auth config", 0, origin, parent_id)

      config ->
        case run_tool_loop(messages, system_prompt, config, core, origin, parent_id) do
          {:ok, response} ->
            response_content = ApiClient.extract_content(response)

            # Store assistant response in session AFTER successful API call
            if chat_id && process_alive?(session) do
              asst_delta =
                Kyber.Delta.new(
                  "session.assistant",
                  %{"role" => "assistant", "content" => response_content},
                  origin
                )

              Kyber.Session.add_message(session, chat_id, asst_delta)
            end

            channel_id =
              case origin do
                {:channel, "discord", cid, _} -> cid
                _ -> nil
              end

            # Log actual token usage for observability
            usage = response["usage"]

            if is_map(usage) do
              input_tokens = Map.get(usage, "input_tokens", 0)
              output_tokens = Map.get(usage, "output_tokens", 0)

              Logger.debug(
                "[LLM] usage: input=#{input_tokens} output=#{output_tokens} total=#{input_tokens + output_tokens}"
              )
            end

            response_payload =
              %{
                "content" => response_content,
                "model" => response["model"],
                "usage" => usage,
                "stop_reason" => response["stop_reason"]
              }
              |> then(fn p ->
                if channel_id, do: Map.put(p, "channel_id", channel_id), else: p
              end)
              |> then(fn p ->
                case payload["message_id"] do
                  nil -> p
                  mid -> Map.put(p, "reply_to_message_id", mid)
                end
              end)
              |> then(fn p ->
                # Propagate streaming preview message ID so the final send_message
                # effect can edit it rather than posting a new message (Issue 1).
                case Map.get(response, "_streaming_message_id") do
                  nil -> p
                  msg_id -> Map.put(p, "streaming_message_id", msg_id)
                end
              end)

            delta =
              Kyber.Delta.new(
                "llm.response",
                response_payload,
                origin || {:system, "llm"},
                parent_id
              )

            try do
              Kyber.Core.emit(core, delta)
            rescue
              e ->
                Logger.error("[Kyber.Plugin.LLM] failed to emit response: #{inspect(e)}")
            end

            # Reinforce memories whose tags appear in the response
            PromptBuilder.reinforce_memories(response_content)

          {:error, %{error: error_msg, status: status}} ->
            emit_error(core, error_msg, status, origin, parent_id)

          {:error, :timeout} ->
            emit_error(core, "LLM call timed out after 90 seconds", 0, origin, parent_id)

          {:error, reason} when is_binary(reason) ->
            emit_error(core, reason, 0, origin, parent_id)

          {:error, reason} ->
            emit_error(core, inspect(reason), 0, origin, parent_id)
        end
    end
  end

  # ── Public: Tool loop ─────────────────────────────────────────────────────

  @doc """
  Multi-turn tool loop. Calls the API, executes any tool_use blocks,
  and repeats until stop_reason is end_turn (or max iterations reached).

  Emits llm.call, tool.call, and tool.result deltas for observability.
  """
  def run_tool_loop(messages, system_prompt, auth_config, core, origin, parent_id, remaining \\ 10)

  def run_tool_loop(_messages, _system_prompt, _auth_config, _core, _origin, _parent_id, 0) do
    {:error, "tool loop limit reached (max 10 iterations)"}
  end

  def run_tool_loop(messages, system_prompt, auth_config, core, origin, parent_id, remaining) do
    tool_defs = Kyber.Tools.definitions()
    model = ApiClient.model()

    # Emit llm.call delta before API call
    llm_call_delta =
      Kyber.Delta.new(
        "llm.call",
        %{"model" => model, "message_count" => length(messages), "tools" => Kyber.Tools.names()},
        origin,
        parent_id
      )

    safe_emit(core, llm_call_delta)

    params = %{
      "model" => model,
      "max_tokens" => @default_max_tokens,
      "messages" => messages,
      "system" => system_prompt,
      "tools" => tool_defs
    }

    case ApiClient.call_api_maybe_stream(auth_config, params, core, origin, parent_id) do
      {:ok, %{"stop_reason" => "tool_use", "content" => content_blocks} = response} ->
        tool_uses = Enum.filter(content_blocks, &(&1["type"] == "tool_use"))
        tool_names = Enum.map_join(tool_uses, ", ", & &1["name"])

        Logger.info(
          "[Kyber.Plugin.LLM] tool_use: #{length(tool_uses)} call(s): #{tool_names}"
        )

        # Edge case: model returned stop_reason=tool_use but no actual tool_use
        # blocks (happens with extended thinking). Treat as end_turn.
        if tool_uses == [] do
          Logger.warning("[LLM] tool_use stop_reason with 0 tool blocks — treating as end_turn")
          {:ok, Map.put(response, "stop_reason", "end_turn")}
        else
          # Send a "working on it" preview to Discord so the user sees activity
          send_tool_preview(origin, content_blocks, tool_names)

          assistant_msg = %{"role" => "assistant", "content" => content_blocks}

          tool_results =
            Enum.map(tool_uses, fn tu ->
              execute_tool(tu, core, origin, parent_id)
            end)

          user_result_msg = %{"role" => "user", "content" => tool_results}

          run_tool_loop(
            messages ++ [assistant_msg, user_result_msg],
            system_prompt,
            auth_config,
            core,
            origin,
            parent_id,
            remaining - 1
          )
        end

      {:ok, response} ->
        {:ok, response}

      {:error, _} = err ->
        err
    end
  end

  @doc false
  def safe_emit(core, delta) do
    try do
      Kyber.Core.emit(core, delta)
    rescue
      e -> Logger.error("[Kyber.Plugin.LLM] failed to emit delta: #{inspect(e)}")
    end
  end

  # Send a tool-use preview to Discord so the user sees what's happening.
  # Extracts any partial text the model produced before the tool calls,
  # appends a tool summary line, and posts it with a ⏳ indicator.
  defp send_tool_preview(origin, content_blocks, tool_names) do
    channel_id =
      case origin do
        {:channel, "discord", cid, _} -> cid
        _ -> nil
      end

    if channel_id do
      token =
        System.get_env("DISCORD_BOT_TOKEN") ||
          Application.get_env(:kyber_beam, :discord_bot_token)

      if token do
        # Extract any text the model said before calling tools
        text_parts =
          content_blocks
          |> Enum.filter(&(&1["type"] == "text"))
          |> Enum.map(&(&1["text"] || ""))
          |> Enum.reject(&(&1 == ""))

        tool_line = "🔧 *Using: #{tool_names}…*"

        preview =
          case text_parts do
            [] -> tool_line <> " ⏳"
            parts -> Enum.join(parts, "\n") <> "\n\n" <> tool_line <> " ⏳"
          end
          |> String.slice(0, 1900)

        # Fire and forget — don't block the tool loop
        Task.start(fn ->
          case Kyber.Plugin.Discord.post_message_with_id(token, channel_id, preview) do
            {:ok, msg_id} ->
              # Store the preview message ID so the final response can edit it
              # We use the process dictionary of the tool loop's process
              # This is picked up by the reducer's send_message effect
              :persistent_term.put({:tool_preview_msg, channel_id}, msg_id)

            _ ->
              :ok
          end
        end)
      end
    end
  end

  # ── Private: Tool execution ───────────────────────────────────────────────

  # Map Anthropic's computer use actions to our computer_use tool format.
  # Anthropic sends: %{"name" => "computer", "input" => %{"action" => "left_click", "coordinate" => [x, y]}}
  # We translate to: %{"name" => "computer_use", "input" => %{"action" => "click", "x" => x, "y" => y}}
  defp translate_computer_tool(%{"name" => "computer", "input" => input} = tu) do
    action = Map.get(input, "action", "screenshot")

    translated_input =
      case action do
        "screenshot" ->
          %{"action" => "screenshot"}

        act when act in ["left_click", "right_click", "double_click", "mouse_move"] ->
          [x, y] = Map.get(input, "coordinate", [0, 0])

          mapped_action =
            case act do
              "left_click" -> "click"
              "right_click" -> "right_click"
              "double_click" -> "double_click"
              "mouse_move" -> "move"
            end

          %{"action" => mapped_action, "x" => x, "y" => y}

        "type" ->
          %{"action" => "type", "text" => Map.get(input, "text", "")}

        "key" ->
          %{"action" => "key", "key" => Map.get(input, "text", "")}

        "scroll" ->
          [_x, _y] = Map.get(input, "coordinate", [0, 0])
          delta_x = Map.get(input, "delta_x", 0)
          delta_y = Map.get(input, "delta_y", 0)

          {direction, amount} =
            cond do
              delta_y < 0 -> {"up", abs(delta_y)}
              delta_y > 0 -> {"down", delta_y}
              delta_x != 0 -> {"down", abs(delta_x)}
              true -> {"down", 3}
            end

          %{
            "action" => "scroll",
            "scroll_direction" => direction,
            "scroll_amount" => max(1, div(amount, 100))
          }

        _ ->
          %{"action" => action}
      end

    %{tu | "name" => "computer_use", "input" => translated_input}
  end

  defp translate_computer_tool(tu), do: tu

  defp execute_tool(tu, core, origin, parent_id) do
    # Translate Anthropic's "computer" tool to our "computer_use" tool
    tu = translate_computer_tool(tu)
    tool_name = tu["name"]
    tool_input = tu["input"] || %{}

    Logger.debug("[Kyber.Plugin.LLM] executing tool: #{tool_name} #{inspect(tool_input)}")

    # Emit tool.call delta before execution
    call_delta =
      Kyber.Delta.new(
        "tool.call",
        %{"name" => tool_name, "input" => tool_input},
        origin,
        parent_id
      )

    safe_emit(core, call_delta)

    case Kyber.ToolExecutor.execute(tool_name, tool_input) do
      {:ok, output} ->
        result_delta =
          Kyber.Delta.new(
            "tool.result",
            %{"name" => tool_name, "status" => "ok", "output" => truncate_output(output)},
            origin,
            call_delta.id
          )

        safe_emit(core, result_delta)

        %{
          "type" => "tool_result",
          "tool_use_id" => tu["id"],
          "content" => output
        }

      {:ok_image, %{"media_type" => media_type, "base64" => b64, "path" => path, "size_bytes" => size}} ->
        Logger.info("[Kyber.Plugin.LLM] view_image: #{path} (#{size} bytes)")

        result_delta =
          Kyber.Delta.new(
            "tool.result",
            %{
              "name" => tool_name,
              "status" => "ok",
              "output" => truncate_output("Image: #{path} (#{size} bytes)"),
              "images" => [
                %{
                  "label" => image_label(tool_name, path),
                  "media_type" => media_type,
                  "base64" => b64
                }
              ]
            },
            origin,
            call_delta.id
          )

        safe_emit(core, result_delta)

        %{
          "type" => "tool_result",
          "tool_use_id" => tu["id"],
          "content" => [
            %{
              "type" => "image",
              "source" => %{
                "type" => "base64",
                "media_type" => media_type,
                "data" => b64
              }
            },
            %{
              "type" => "text",
              "text" => "Image loaded: #{path} (#{size} bytes)"
            }
          ]
        }

      {:error, err} ->
        Logger.warning("[Kyber.Plugin.LLM] tool error (#{tool_name}): #{err}")

        result_delta =
          Kyber.Delta.new(
            "tool.result",
            %{"name" => tool_name, "status" => "error", "output" => truncate_output(err)},
            origin,
            call_delta.id
          )

        safe_emit(core, result_delta)

        %{
          "type" => "tool_result",
          "tool_use_id" => tu["id"],
          "content" => "Error: #{err}",
          "is_error" => true
        }
    end
  end

  # ── Private: Helpers ──────────────────────────────────────────────────────

  defp emit_error(core, error_msg, status, origin, parent_id) do
    delta =
      Kyber.Delta.new(
        "llm.error",
        %{"error" => error_msg, "status" => status},
        origin || {:system, "llm"},
        parent_id
      )

    try do
      Kyber.Core.emit(core, delta)
    rescue
      e -> Logger.error("[Kyber.Plugin.LLM] failed to emit error delta: #{inspect(e)}")
    end
  end

  defp truncate_output(output, max \\ 500) do
    str = if is_binary(output), do: output, else: inspect(output)

    if String.length(str) > max do
      String.slice(str, 0, max) <> "…"
    else
      str
    end
  end

  defp chat_id_from_origin({:channel, _ch, chat_id, _sender}), do: chat_id
  defp chat_id_from_origin({:human, user_id}), do: user_id
  defp chat_id_from_origin(_), do: nil

  defp process_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp process_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp process_alive?(_), do: false

  defp image_label("computer_use", _path), do: "Screenshot"
  defp image_label("browser", _path), do: "Browser Screenshot"
  defp image_label("camera", _path), do: "Camera Snap"
  defp image_label(tool_name, path) do
    cond do
      String.contains?(to_string(path), "screenshot") -> "Screenshot (#{tool_name})"
      true -> "Image (#{tool_name})"
    end
  end
end
