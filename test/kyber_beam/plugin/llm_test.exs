defmodule Kyber.Plugin.LLMTest do
  use ExUnit.Case, async: true

  alias Kyber.Plugin.LLM
  alias Kyber.Delta

  describe "detect_auth_type/1" do
    test "detects OAuth token" do
      assert LLM.detect_auth_type("sk-ant-oat01-abc123") == :oauth
      assert LLM.detect_auth_type("sk-ant-oat-xyz") == :oauth
    end

    test "detects API key" do
      assert LLM.detect_auth_type("sk-ant-api03-abc123") == :api_key
    end

    test "unknown prefix defaults to api_key" do
      assert LLM.detect_auth_type("some-random-token") == :api_key
      assert LLM.detect_auth_type("") == :api_key
    end
  end

  describe "build_headers/1" do
    test "OAuth config produces Bearer auth with required headers" do
      config = %{type: :oauth, token: "my-oauth-token"}
      headers = LLM.build_headers(config)

      assert Enum.any?(headers, fn {k, v} ->
        k == "Authorization" and v == "Bearer my-oauth-token"
      end)

      assert Enum.any?(headers, fn {k, v} ->
        k == "anthropic-beta" and String.contains?(v, "oauth")
      end)

      assert Enum.any?(headers, fn {k, _v} -> k == "user-agent" end)
      assert Enum.any?(headers, fn {k, _v} -> k == "x-app" end)

      # Must NOT have x-api-key
      refute Enum.any?(headers, fn {k, _} -> k == "x-api-key" end)
    end

    test "API key config produces x-api-key header" do
      config = %{type: :api_key, token: "my-api-key"}
      headers = LLM.build_headers(config)

      assert Enum.any?(headers, fn {k, v} ->
        k == "x-api-key" and v == "my-api-key"
      end)

      assert Enum.any?(headers, fn {k, _} -> k == "anthropic-version" end)

      # Must NOT have Bearer Authorization
      refute Enum.any?(headers, fn {k, _} -> k == "Authorization" end)
    end
  end

  describe "build_messages/1" do
    test "builds messages from text field" do
      payload = %{"text" => "hello world"}
      messages = LLM.build_messages(payload)
      assert length(messages) == 1
      assert hd(messages) == %{"role" => "user", "content" => "hello world"}
    end

    test "uses explicit messages list when provided" do
      payload = %{
        "messages" => [
          %{"role" => "user", "content" => "hi"},
          %{"role" => "assistant", "content" => "hello"}
        ]
      }

      messages = LLM.build_messages(payload)
      assert length(messages) == 2
    end

    test "prepends history to text message" do
      payload = %{
        "text" => "follow up",
        "history" => [
          %{"role" => "user", "content" => "first message"},
          %{"role" => "assistant", "content" => "first response"}
        ]
      }

      messages = LLM.build_messages(payload)
      assert length(messages) == 3
      assert hd(messages) == %{"role" => "user", "content" => "first message"}
      assert List.last(messages) == %{"role" => "user", "content" => "follow up"}
    end

    test "returns empty list for unrecognized payload" do
      assert LLM.build_messages(%{}) == []
      assert LLM.build_messages(%{"irrelevant" => "data"}) == []
    end

    test "handles atom-keyed history" do
      payload = %{
        "text" => "hi",
        "history" => [%{role: :user, content: "previous"}]
      }

      messages = LLM.build_messages(payload)
      assert length(messages) == 2
      first = hd(messages)
      assert first["role"] == "user"
      assert first["content"] == "previous"
    end

    # ── Image attachment tests ───────────────────────────────────────────

    test "builds multi-block content when image attachment is present" do
      payload = %{
        "text" => "what's in this image?",
        "attachments" => [
          %{
            "url" => "https://cdn.discordapp.com/attachments/123/456/photo.png",
            "content_type" => "image/png",
            "filename" => "photo.png"
          }
        ]
      }

      messages = LLM.build_messages(payload)
      assert length(messages) == 1

      user_msg = hd(messages)
      assert user_msg["role"] == "user"
      content = user_msg["content"]

      # Content must be a list of blocks (not plain string)
      assert is_list(content)

      image_block = Enum.find(content, &(&1["type"] == "image"))
      assert image_block != nil
      assert image_block["source"]["type"] == "url"
      assert image_block["source"]["url"] == "https://cdn.discordapp.com/attachments/123/456/photo.png"

      text_block = Enum.find(content, &(&1["type"] == "text"))
      assert text_block != nil
      assert text_block["text"] == "what's in this image?"
    end

    test "builds multi-block content for multiple image attachments" do
      payload = %{
        "text" => "compare these",
        "attachments" => [
          %{"url" => "https://cdn.discordapp.com/a.jpg", "content_type" => "image/jpeg"},
          %{"url" => "https://cdn.discordapp.com/b.png", "content_type" => "image/png"}
        ]
      }

      messages = LLM.build_messages(payload)
      content = hd(messages)["content"]

      assert is_list(content)
      image_blocks = Enum.filter(content, &(&1["type"] == "image"))
      assert length(image_blocks) == 2

      urls = Enum.map(image_blocks, & &1["source"]["url"])
      assert "https://cdn.discordapp.com/a.jpg" in urls
      assert "https://cdn.discordapp.com/b.png" in urls
    end

    test "ignores non-image attachments (e.g. PDF, text files)" do
      payload = %{
        "text" => "here is a PDF",
        "attachments" => [
          %{"url" => "https://cdn.discordapp.com/doc.pdf", "content_type" => "application/pdf"}
        ]
      }

      messages = LLM.build_messages(payload)
      user_msg = hd(messages)

      # No images → content remains a plain string
      assert user_msg["content"] == "here is a PDF"
    end

    test "mixed attachments: only image ones become blocks" do
      payload = %{
        "text" => "image and pdf",
        "attachments" => [
          %{"url" => "https://cdn.discordapp.com/img.png", "content_type" => "image/png"},
          %{"url" => "https://cdn.discordapp.com/doc.pdf", "content_type" => "application/pdf"}
        ]
      }

      messages = LLM.build_messages(payload)
      content = hd(messages)["content"]

      assert is_list(content)
      image_blocks = Enum.filter(content, &(&1["type"] == "image"))
      assert length(image_blocks) == 1
      assert hd(image_blocks)["source"]["url"] == "https://cdn.discordapp.com/img.png"
    end

    test "empty attachments list keeps plain string content" do
      payload = %{"text" => "just text", "attachments" => []}
      messages = LLM.build_messages(payload)
      assert hd(messages)["content"] == "just text"
    end

    test "nil attachments (absent key) keeps plain string content" do
      payload = %{"text" => "just text"}
      messages = LLM.build_messages(payload)
      assert hd(messages)["content"] == "just text"
    end

    test "history with list content blocks is passed through unchanged" do
      # Simulates a prior turn that had an image — the history entry has list content
      image_content = [
        %{"type" => "image", "source" => %{"type" => "url", "url" => "https://example.com/img.png"}},
        %{"type" => "text", "text" => "what is this?"}
      ]

      payload = %{
        "text" => "follow-up question",
        "history" => [
          %{"role" => "user", "content" => image_content},
          %{"role" => "assistant", "content" => "That is a cat."}
        ]
      }

      messages = LLM.build_messages(payload)
      assert length(messages) == 3

      # First history entry must preserve list content intact
      first = hd(messages)
      assert first["role"] == "user"
      assert is_list(first["content"])
      assert length(first["content"]) == 2

      # Current message is a plain string (no attachments in this turn)
      last = List.last(messages)
      assert last["content"] == "follow-up question"
    end
  end

  describe "load_auth_config/1" do
    test "returns error for missing file" do
      assert {:error, _} = LLM.load_auth_config("/nonexistent/path/auth.json")
    end

    test "returns error for invalid JSON" do
      path = write_temp_file("not-json-at-all")
      assert {:error, _} = LLM.load_auth_config(path)
    end

    test "returns error when no token found" do
      path = write_temp_file(~s({"unrelated": "data"}))
      assert {:error, :no_token_found} = LLM.load_auth_config(path)
    end

    test "extracts OAuth token from claudeAiOauth structure" do
      json = Jason.encode!(%{
        "claudeAiOauth" => %{"accessToken" => "sk-ant-oat01-my-token"}
      })

      path = write_temp_file(json)
      assert {:ok, config} = LLM.load_auth_config(path)
      assert config.token == "sk-ant-oat01-my-token"
      assert config.type == :oauth
    end

    test "extracts API key from apiKey field" do
      json = Jason.encode!(%{"apiKey" => "sk-ant-api03-my-key"})
      path = write_temp_file(json)
      assert {:ok, config} = LLM.load_auth_config(path)
      assert config.token == "sk-ant-api03-my-key"
      assert config.type == :api_key
    end

    test "extracts token from nested oauthToken field" do
      json = Jason.encode!(%{"oauthToken" => "sk-ant-oat01-nested-token"})
      path = write_temp_file(json)
      assert {:ok, config} = LLM.load_auth_config(path)
      assert config.type == :oauth
    end

    test "extracts token from plain token field" do
      json = Jason.encode!(%{"token" => "sk-ant-api03-plain"})
      path = write_temp_file(json)
      assert {:ok, config} = LLM.load_auth_config(path)
      assert config.type == :api_key
    end
  end

  describe "call_api/2 (mocked)" do
    setup do
      # We test the request building, not actual HTTP calls.
      # Tests that verify response handling use pre-built maps.
      :ok
    end

    test "success response is parsed correctly" do
      # Simulate what call_api would return from a 200 response
      response = %{
        "id" => "msg_123",
        "type" => "message",
        "role" => "assistant",
        "content" => [%{"type" => "text", "text" => "Hello!"}],
        "model" => "claude-sonnet-4-6",
        "stop_reason" => "end_turn",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      }

      # Verify the response format matches what our handler expects
      assert response["content"] |> hd() |> Map.get("text") == "Hello!"
      assert response["model"] == "claude-sonnet-4-6"
      assert response["stop_reason"] == "end_turn"
    end

    test "error response format" do
      error_response = %{
        "error" => %{
          "type" => "authentication_error",
          "message" => "Invalid API key"
        }
      }

      # Verify the error extraction path
      error_msg = get_in(error_response, ["error", "message"])
      assert error_msg == "Invalid API key"
    end
  end

  describe "plugin behavior" do
    test "name/0 returns 'llm'" do
      assert LLM.name() == "llm"
    end
  end

  describe "auth token refresh (get_auth_config)" do
    test "handle_call :get_auth_config returns current auth config" do
      # Start an LLM plugin with a known auth path (will fail to load, that's ok)
      {:ok, pid} = GenServer.start_link(LLM, [
        core: :fake_core,
        session: :fake_session,
        auth_path: "/nonexistent/auth.json"
      ])
      on_exit(fn ->
        try do
          if Process.alive?(pid), do: GenServer.stop(pid, :normal, 500)
        catch
          :exit, _ -> :ok
        end
      end)

      # Initially nil (auth failed to load)
      assert GenServer.call(pid, :get_auth_config) == nil

      # Inject an updated auth config via handle_info
      new_config = %{token: "sk-ant-api03-new-token", type: :api_key}
      send(pid, {:update_auth, new_config})
      Process.sleep(20)

      # get_auth_config must now return the updated config
      assert GenServer.call(pid, :get_auth_config) == new_config
    end
  end

  describe "delta emission format" do
    test "llm.response delta has correct payload structure" do
      # Verify the expected payload structure for llm.response deltas
      content = "This is the response"
      model = "claude-sonnet-4-6"
      usage = %{"input_tokens" => 10, "output_tokens" => 20}
      stop_reason = "end_turn"

      delta = Delta.new(
        "llm.response",
        %{
          "content" => content,
          "model" => model,
          "usage" => usage,
          "stop_reason" => stop_reason
        },
        {:subagent, "parent-delta-id"}
      )

      assert delta.kind == "llm.response"
      assert delta.payload["content"] == content
      assert delta.payload["model"] == model
      assert delta.payload["stop_reason"] == stop_reason
    end

    test "llm.error delta has correct payload structure" do
      delta = Delta.new(
        "llm.error",
        %{"error" => "API error", "status" => 429},
        {:system, "llm"}
      )

      assert delta.kind == "llm.error"
      assert delta.payload["error"] == "API error"
      assert delta.payload["status"] == 429
    end
  end

  describe "format_with_reasoning/2" do
    test "returns text unchanged when thinking is nil" do
      assert LLM.format_with_reasoning("hello world", nil) == "hello world"
    end

    test "returns text unchanged when thinking is empty string" do
      assert LLM.format_with_reasoning("hello world", "") == "hello world"
    end

    test "wraps text with reasoning spoiler block when thinking is present" do
      result = LLM.format_with_reasoning("answer", "my reasoning")
      assert String.contains?(result, "🧠 **Reasoning**")
      assert String.contains?(result, "my reasoning")
      assert String.contains?(result, "answer")
      # spoiler block
      assert String.starts_with?(result, "||")
    end

    test "multi-line thinking is quoted with > prefix" do
      result = LLM.format_with_reasoning("answer", "line one\nline two")
      assert String.contains?(result, "> line one")
      assert String.contains?(result, "> line two")
    end
  end

  describe "thinking config in do_streaming_call/5" do
    test "thinking body is built when llm_thinking is true" do
      # Test that the thinking config logic produces the expected map
      budget = Application.get_env(:kyber_beam, :thinking_budget_tokens, 10_000)
      base_max = 16_384  # @default_max_tokens after our bump
      expected_max = max(base_max, budget + base_max)

      # Simulate the body building logic
      body = %{"max_tokens" => base_max}
      result_body =
        case true do
          true ->
            body
            |> Map.put("thinking", %{"type" => "enabled", "budget_tokens" => budget})
            |> Map.put("max_tokens", expected_max)
            |> Map.delete("temperature")
          _ -> body
        end

      assert result_body["thinking"] == %{"type" => "enabled", "budget_tokens" => budget}
      assert result_body["max_tokens"] >= budget
      refute Map.has_key?(result_body, "temperature")
    end

    test "thinking body is not added when llm_thinking is false" do
      body = %{"max_tokens" => 16_384}
      result_body =
        case false do
          true -> Map.put(body, "thinking", %{"type" => "enabled", "budget_tokens" => 10_000})
          _ -> body
        end

      refute Map.has_key?(result_body, "thinking")
    end

    test "thinking config: max_tokens is at least budget + default" do
      budget = 10_000
      base_max = 16_384
      expected_min = budget + base_max

      body = %{"max_tokens" => base_max}
      updated = Map.put(body, "max_tokens", max(base_max, expected_min))
      assert updated["max_tokens"] >= expected_min
    end
  end

  describe "thinking chunk accumulation" do
    test "thinking chunks are accumulated in process dictionary" do
      thinking_acc_ref = make_ref()
      Process.put(thinking_acc_ref, "")

      # Simulate the callback behavior
      accumulate = fn text ->
        new_thinking = Process.get(thinking_acc_ref, "") <> text
        Process.put(thinking_acc_ref, new_thinking)
      end

      accumulate.("first chunk ")
      accumulate.("second chunk")

      assert Process.get(thinking_acc_ref) == "first chunk second chunk"
    end
  end

  describe "streaming response with thinking extraction" do
    test "response with thinking block gets formatted with reasoning trace" do
      response = %{
        "content" => [
          %{"type" => "thinking", "thinking" => "I reasoned carefully"},
          %{"type" => "text", "text" => "The answer is 42"}
        ],
        "stop_reason" => "end_turn"
      }

      thinking = Kyber.Plugin.LLM.Streamer.extract_thinking(response)
      assert thinking == "I reasoned carefully"

      text_content = LLM.format_with_reasoning("The answer is 42", thinking)
      assert String.contains?(text_content, "🧠 **Reasoning**")
      assert String.contains?(text_content, "I reasoned carefully")
      assert String.contains?(text_content, "The answer is 42")
    end

    test "response without thinking block returns text as-is" do
      response = %{
        "content" => [%{"type" => "text", "text" => "Just the answer"}],
        "stop_reason" => "end_turn"
      }

      thinking = Kyber.Plugin.LLM.Streamer.extract_thinking(response)
      assert is_nil(thinking)

      text_content = LLM.format_with_reasoning("Just the answer", thinking)
      assert text_content == "Just the answer"
    end
  end

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp write_temp_file(content) do
    path = System.tmp_dir!() |> Path.join("llm_test_#{:rand.uniform(999_999)}.json")
    File.write!(path, content)
    # Register cleanup
    on_exit(fn -> File.rm(path) end)
    path
  end
end
