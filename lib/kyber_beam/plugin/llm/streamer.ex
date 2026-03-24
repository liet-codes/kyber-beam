defmodule Kyber.Plugin.LLM.Streamer do
  @moduledoc """
  SSE streaming for Anthropic API responses.

  Handles the streaming Messages API, reconstructing a full response body
  (compatible with non-streaming format) while emitting incremental chunks
  via an optional callback function.

  The reconstructed response has the same shape as a non-streaming response:
      %{
        "stop_reason" => "end_turn" | "tool_use" | ...,
        "content"     => [%{"type" => "text", "text" => "..."}, ...],
        "usage"       => %{"input_tokens" => N, "output_tokens" => M}
      }

  Callback receives:
    - `{:thinking_chunk, text}` — incremental extended thinking text
    - `{:text_chunk, text}`    — incremental response text
    - `{:done, stop_reason}`  — streaming complete
  """

  require Logger

  @doc """
  Make a streaming API call to Anthropic.

  Returns `{:ok, reconstructed_response}` or `{:error, reason}`.

  `callback_fn` receives incremental events (may be `nil` to skip callbacks).
  """
  @spec stream_request(String.t(), map(), list(), function() | nil) ::
          {:ok, map()} | {:error, term()}
  def stream_request(url, body, headers, callback_fn \\ nil) do
    stream_body = Map.put(body, "stream", true)

    # Accumulator state for reconstructing the full response
    acc = %{
      # index → %{type: "text"|"tool_use"|"thinking", text: "", ...}
      blocks: %{},
      current_index: nil,
      stop_reason: nil,
      stop_sequence: nil,
      usage: nil,
      model: nil
    }

    result_ref = make_ref()
    Process.put(result_ref, {:streaming, acc})

    cb = callback_fn || fn _ -> :ok end

    case Req.post(url,
           json: stream_body,
           headers: headers,
           receive_timeout: 120_000,
           into: fn {:data, chunk}, {req, resp} ->
             current = Process.get(result_ref)

             case current do
               {:streaming, state} ->
                 new_state = parse_sse_chunk(chunk, state, cb)
                 Process.put(result_ref, {:streaming, new_state})

               _ ->
                 :ok
             end

             {:cont, {req, resp}}
           end
         ) do
      {:ok, %{status: 200}} ->
        case Process.get(result_ref) do
          {:streaming, final_state} ->
            response = reconstruct_response(final_state)
            {:ok, response}

          _ ->
            {:error, "unexpected streamer state"}
        end

      {:ok, %{status: status, body: body}} ->
        error_msg = get_in(body, ["error", "message"]) || inspect(body)
        {:error, %{error: error_msg, status: status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── SSE chunk parser ──────────────────────────────────────────────────────

  defp parse_sse_chunk(data, state, cb) do
    data
    |> String.split("\n")
    |> Enum.reduce(state, fn line, acc ->
      case line do
        "data: " <> json_str ->
          case Jason.decode(json_str) do
            {:ok, event} -> handle_event(event, acc, cb)
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp handle_event(%{"type" => "message_start", "message" => msg}, state, _cb) do
    %{state | model: msg["model"], usage: msg["usage"]}
  end

  defp handle_event(%{"type" => "content_block_start", "index" => idx, "content_block" => block}, state, _cb) do
    block_type = block["type"]

    new_block =
      case block_type do
        "text" -> %{type: "text", text: ""}
        "thinking" -> %{type: "thinking", thinking: ""}
        "tool_use" -> %{type: "tool_use", id: block["id"], name: block["name"], input: ""}
        _ -> %{type: block_type, raw: block}
      end

    %{state | blocks: Map.put(state.blocks, idx, new_block), current_index: idx}
  end

  defp handle_event(
         %{"type" => "content_block_delta", "index" => idx, "delta" => delta},
         state,
         cb
       ) do
    block = Map.get(state.blocks, idx, %{type: "text", text: ""})

    updated_block =
      case delta do
        %{"type" => "text_delta", "text" => text} ->
          new_text = (block[:text] || "") <> text
          cb.({:text_chunk, text})
          %{block | text: new_text}

        %{"type" => "thinking_delta", "thinking" => text} ->
          new_thinking = (block[:thinking] || "") <> text
          cb.({:thinking_chunk, text})
          %{block | thinking: new_thinking}

        %{"type" => "input_json_delta", "partial_json" => partial} ->
          new_input = (block[:input] || "") <> partial
          %{block | input: new_input}

        _ ->
          block
      end

    %{state | blocks: Map.put(state.blocks, idx, updated_block)}
  end

  defp handle_event(%{"type" => "content_block_stop"}, state, _cb), do: state

  defp handle_event(%{"type" => "message_delta", "delta" => delta, "usage" => usage}, state, cb) do
    stop_reason = delta["stop_reason"]
    if stop_reason, do: cb.({:done, stop_reason})

    # Merge output tokens into usage
    merged_usage =
      case state.usage do
        nil -> usage
        existing -> Map.merge(existing, usage || %{})
      end

    %{state | stop_reason: stop_reason, stop_sequence: delta["stop_sequence"], usage: merged_usage}
  end

  defp handle_event(%{"type" => "message_stop"}, state, _cb), do: state
  defp handle_event(_event, state, _cb), do: state

  # ── Response reconstruction ───────────────────────────────────────────────

  defp reconstruct_response(state) do
    content_blocks =
      state.blocks
      |> Enum.sort_by(fn {idx, _} -> idx end)
      |> Enum.map(fn {_, block} ->
        case block do
          %{type: "text", text: text} ->
            %{"type" => "text", "text" => text}

          %{type: "thinking", thinking: thinking} ->
            %{"type" => "thinking", "thinking" => thinking}

          %{type: "tool_use", id: id, name: name, input: input_json} ->
            parsed_input =
              case Jason.decode(input_json) do
                {:ok, parsed} -> parsed
                _ -> %{}
              end

            %{"type" => "tool_use", "id" => id, "name" => name, "input" => parsed_input}

          _ ->
            nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    %{
      "stop_reason" => state.stop_reason || "end_turn",
      "stop_sequence" => state.stop_sequence,
      "content" => content_blocks,
      "usage" => state.usage,
      "model" => state.model
    }
  end

  # ── Thinking extraction helpers ───────────────────────────────────────────

  @doc "Extract thinking text from reconstructed response content blocks."
  @spec extract_thinking(map()) :: String.t() | nil
  def extract_thinking(%{"content" => blocks}) when is_list(blocks) do
    case Enum.find(blocks, &(&1["type"] == "thinking")) do
      %{"thinking" => text} when is_binary(text) and text != "" -> text
      _ -> nil
    end
  end

  def extract_thinking(_), do: nil
end
