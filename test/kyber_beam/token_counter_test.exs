defmodule Kyber.TokenCounterTest do
  use ExUnit.Case, async: true

  alias Kyber.TokenCounter

  describe "estimate_tokens/1" do
    test "empty string returns 0" do
      assert TokenCounter.estimate_tokens("") == 0
    end

    test "string shorter than 4 chars returns 0" do
      assert TokenCounter.estimate_tokens("Hi") == 0
    end

    test "4-char string returns 1 token" do
      assert TokenCounter.estimate_tokens("test") == 1
    end

    test "estimates ~4 chars per token" do
      # 40 chars → ~10 tokens
      text = String.duplicate("a", 40)
      assert TokenCounter.estimate_tokens(text) == 10
    end

    test "non-string returns 0" do
      assert TokenCounter.estimate_tokens(nil) == 0
      assert TokenCounter.estimate_tokens(42) == 0
    end

    test "longer text scales linearly" do
      text100 = String.duplicate("x", 100)
      text400 = String.duplicate("x", 400)
      assert TokenCounter.estimate_tokens(text400) == 4 * TokenCounter.estimate_tokens(text100)
    end
  end

  describe "estimate_message_tokens/1" do
    test "plain string content message" do
      msg = %{"role" => "user", "content" => String.duplicate("a", 80)}
      # 80 chars = 20 tokens + 4 overhead = 24
      assert TokenCounter.estimate_message_tokens(msg) == 24
    end

    test "empty content message returns overhead tokens" do
      msg = %{"role" => "user", "content" => ""}
      # Empty string → 0 content tokens + 4 overhead
      assert TokenCounter.estimate_message_tokens(msg) == 4
    end

    test "content block list — text block" do
      msg = %{
        "role" => "user",
        "content" => [
          %{"type" => "text", "text" => String.duplicate("a", 40)}
        ]
      }
      # 40 chars = 10 tokens + 4 overhead = 14
      assert TokenCounter.estimate_message_tokens(msg) == 14
    end

    test "content block list — image block" do
      msg = %{
        "role" => "user",
        "content" => [
          %{"type" => "image", "source" => %{"type" => "url"}},
          %{"type" => "text", "text" => "what is this?"}
        ]
      }
      tokens = TokenCounter.estimate_message_tokens(msg)
      # Image = 1000 + text tokens + overhead
      assert tokens >= 1000
    end

    test "tool_use block" do
      msg = %{
        "role" => "assistant",
        "content" => [
          %{
            "type" => "tool_use",
            "name" => "bash",
            "id" => "tu_1",
            "input" => %{"command" => "ls -la"}
          }
        ]
      }
      tokens = TokenCounter.estimate_message_tokens(msg)
      assert tokens > 4
    end

    test "tool_result block with string content" do
      msg = %{
        "role" => "user",
        "content" => [
          %{
            "type" => "tool_result",
            "tool_use_id" => "tu_1",
            "content" => String.duplicate("a", 80)
          }
        ]
      }
      # 80 chars = 20 tokens + 4 overhead = 24
      assert TokenCounter.estimate_message_tokens(msg) == 24
    end

    test "Kyber.Delta struct" do
      delta = %Kyber.Delta{
        id: "test",
        kind: "session.user",
        payload: %{"role" => "user", "content" => String.duplicate("b", 40)},
        ts: DateTime.utc_now(),
        origin: nil,
        parent_id: nil
      }
      # 40 chars = 10 tokens + 4 overhead = 14
      assert TokenCounter.estimate_message_tokens(delta) == 14
    end

    test "unknown map returns overhead" do
      assert TokenCounter.estimate_message_tokens(%{}) == 4
    end
  end

  describe "trim_to_budget/2" do
    test "empty list returns empty" do
      assert {[], 0, 0} = TokenCounter.trim_to_budget([])
    end

    test "single message is always kept" do
      msg = %{"role" => "user", "content" => "hi"}
      {kept, dropped, _tokens} = TokenCounter.trim_to_budget([msg], budget: 1)
      assert kept == [msg]
      assert dropped == 0
    end

    test "all messages fit within budget" do
      messages = [
        %{"role" => "user", "content" => "hello"},
        %{"role" => "assistant", "content" => "hi there"},
        %{"role" => "user", "content" => "how are you?"}
      ]
      {kept, dropped, tokens} = TokenCounter.trim_to_budget(messages, budget: 1_000)
      # All messages fit — returned in chronological order (oldest first)
      assert length(kept) == 3
      assert dropped == 0
      assert tokens > 0
      assert List.last(kept) == List.last(messages)
      assert hd(kept) == hd(messages)
    end

    test "drops oldest messages when over budget" do
      # 3 messages of ~25 tokens each (~100 chars). Budget = 30 → fits only latest 1.
      old1 = %{"role" => "user", "content" => String.duplicate("a", 100)}
      old2 = %{"role" => "assistant", "content" => String.duplicate("b", 100)}
      newest = %{"role" => "user", "content" => String.duplicate("c", 100)}

      {kept, dropped, _tokens} = TokenCounter.trim_to_budget([old1, old2, newest], budget: 30)
      # newest always kept; old ones dropped
      assert newest in kept
      assert dropped >= 1
    end

    test "preserves chronological order of kept messages" do
      messages =
        Enum.map(1..5, fn i ->
          %{"role" => "user", "content" => "message #{i}"}
        end)

      {kept, _dropped, _tokens} = TokenCounter.trim_to_budget(messages, budget: 50)
      # Kept messages should be in the same relative order (newest at end)
      last_kept = List.last(kept)
      assert last_kept == List.last(messages)
    end

    test "uses application config for default budget" do
      # With a tight budget, older messages should be dropped
      Application.put_env(:kyber_beam, :max_context_tokens, 10)
      Kyber.Config.reload!()

      messages = [
        %{"role" => "user", "content" => String.duplicate("x", 200)},
        %{"role" => "user", "content" => "hi"}
      ]

      {_kept, dropped, _tokens} = TokenCounter.trim_to_budget(messages)
      assert dropped >= 1

      # Restore default
      Application.put_env(:kyber_beam, :max_context_tokens, 180_000)
      Kyber.Config.reload!()
    end

    test "estimated tokens are reasonable" do
      messages = [
        %{"role" => "user", "content" => String.duplicate("a", 400)},
        %{"role" => "assistant", "content" => String.duplicate("b", 400)}
      ]
      {_kept, _dropped, tokens} = TokenCounter.trim_to_budget(messages, budget: 1_000)
      # 800 chars / 4 + overhead per message ≈ 208 tokens
      assert tokens >= 100
      assert tokens <= 500
    end
  end
end
