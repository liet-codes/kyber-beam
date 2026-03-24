defmodule Kyber.TokenCounter do
  @moduledoc """
  Lightweight token estimation for Anthropic API context management.

  Uses a ~4 chars/token heuristic (good enough for English). This is
  intentionally approximate — the goal is to stay well within the context
  window, not to count tokens perfectly.

  ## Usage

      iex> Kyber.TokenCounter.estimate_tokens("Hello, world!")
      3

      iex> Kyber.TokenCounter.estimate_message_tokens(%{"role" => "user", "content" => "Hi"})
      1
  """

  @chars_per_token 4

  @doc """
  Estimate the number of tokens in a plain text string.

  Uses the ~4 chars/token heuristic.
  """
  @spec estimate_tokens(String.t()) :: integer()
  def estimate_tokens(text) when is_binary(text) do
    div(String.length(text), @chars_per_token)
  end

  def estimate_tokens(_), do: 0

  @doc """
  Estimate the number of tokens in a message map.

  Handles:
  - Plain string content: `%{"role" => "user", "content" => "..."}`
  - Content blocks: `%{"role" => "user", "content" => [%{"type" => "text", "text" => "..."}]}`
  - Tool use blocks: `%{"type" => "tool_use", "input" => %{...}}`
  - Tool result blocks: `%{"type" => "tool_result", "content" => "..."}`
  - Kyber.Delta structs (session.user / session.assistant)

  Adds a small overhead per message for role/structure tokens.
  """
  @spec estimate_message_tokens(map() | Kyber.Delta.t()) :: integer()
  def estimate_message_tokens(%Kyber.Delta{payload: payload}) do
    content = Map.get(payload, "content", "")
    estimate_message_tokens(%{"role" => Map.get(payload, "role", "user"), "content" => content})
  end

  def estimate_message_tokens(%{"content" => content} = _msg) when is_binary(content) do
    # ~4 overhead tokens per message for role/structure
    4 + estimate_tokens(content)
  end

  def estimate_message_tokens(%{"content" => content_blocks}) when is_list(content_blocks) do
    block_tokens =
      Enum.reduce(content_blocks, 0, fn block, acc ->
        acc + estimate_content_block_tokens(block)
      end)

    4 + block_tokens
  end

  def estimate_message_tokens(_), do: 4

  # ── Private ───────────────────────────────────────────────────────────────

  defp estimate_content_block_tokens(%{"type" => "text", "text" => text}) when is_binary(text) do
    estimate_tokens(text)
  end

  defp estimate_content_block_tokens(%{"type" => "tool_use", "input" => input, "name" => name}) do
    name_tokens = estimate_tokens(name || "")
    input_tokens = estimate_tokens(inspect(input))
    name_tokens + input_tokens
  end

  defp estimate_content_block_tokens(%{"type" => "tool_result", "content" => content}) do
    case content do
      text when is_binary(text) -> estimate_tokens(text)
      blocks when is_list(blocks) ->
        Enum.reduce(blocks, 0, fn b, acc ->
          acc + estimate_content_block_tokens(b)
        end)
      _ -> 4
    end
  end

  defp estimate_content_block_tokens(%{"type" => "image"}) do
    # Images are expensive — conservatively estimate 1000 tokens for a thumbnail
    1_000
  end

  defp estimate_content_block_tokens(block) when is_map(block) do
    # Unknown block type — try to extract any text-like fields
    block
    |> Map.values()
    |> Enum.filter(&is_binary/1)
    |> Enum.reduce(0, fn v, acc -> acc + estimate_tokens(v) end)
  end

  defp estimate_content_block_tokens(_), do: 0

  @doc """
  Trim a list of messages (oldest first) to fit within a token budget.

  Always preserves the last message (most recent user turn). Drops oldest
  messages first. Returns `{trimmed_messages, dropped_count, estimated_tokens}`.

  ## Options

  - `:budget` — max tokens (default: from `config :kyber_beam, :max_context_tokens`)
  """
  @spec trim_to_budget([map()], keyword()) :: {[map()], non_neg_integer(), non_neg_integer()}
  def trim_to_budget(messages, opts \\ []) when is_list(messages) do
    budget = Keyword.get(opts, :budget, Kyber.Config.get(:max_context_tokens, 180_000))
    do_trim(messages, budget)
  end

  defp do_trim([], _budget), do: {[], 0, 0}
  defp do_trim([_] = messages, _budget), do: {messages, 0, estimate_message_tokens(hd(messages))}

  defp do_trim(messages, budget) do
    # Walk from newest to oldest, accumulate until budget is exceeded.
    # Prepending while iterating newest→oldest naturally builds oldest→newest order.
    total = length(messages)

    {kept, tokens_used} =
      messages
      |> Enum.reverse()
      |> Enum.reduce_while({[], 0}, fn msg, {acc, tokens} ->
        msg_tokens = estimate_message_tokens(msg)
        new_total = tokens + msg_tokens

        if new_total <= budget do
          {:cont, {[msg | acc], new_total}}
        else
          {:halt, {acc, tokens}}
        end
      end)

    dropped = total - length(kept)
    {kept, dropped, tokens_used}
  end
end
