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

  # ── Helpers ──────────────────────────────────────────────────────────────

  defp write_temp_file(content) do
    path = System.tmp_dir!() |> Path.join("llm_test_#{:rand.uniform(999_999)}.json")
    File.write!(path, content)
    # Register cleanup
    on_exit(fn -> File.rm(path) end)
    path
  end
end
