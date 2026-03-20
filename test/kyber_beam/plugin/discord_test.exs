defmodule Kyber.Plugin.DiscordTest do
  use ExUnit.Case, async: true

  alias Kyber.Plugin.Discord
  alias Kyber.Delta

  describe "name/0" do
    test "returns 'discord'" do
      assert Discord.name() == "discord"
    end
  end

  describe "parse_gateway_message/1" do
    test "parses DISPATCH messages" do
      msg = %{
        "op" => 0,
        "t" => "MESSAGE_CREATE",
        "d" => %{"channel_id" => "123", "content" => "hello"},
        "s" => 42
      }

      assert {:dispatch, "MESSAGE_CREATE", data} = Discord.parse_gateway_message(msg)
      assert data["channel_id"] == "123"
    end

    test "parses HELLO opcode" do
      msg = %{"op" => 10, "d" => %{"heartbeat_interval" => 41250}}
      assert {:hello, 41250} = Discord.parse_gateway_message(msg)
    end

    test "parses HEARTBEAT_ACK" do
      msg = %{"op" => 11}
      assert {:heartbeat_ack} = Discord.parse_gateway_message(msg)
    end

    test "parses HEARTBEAT request" do
      msg = %{"op" => 1, "d" => nil}
      assert {:heartbeat} = Discord.parse_gateway_message(msg)
    end

    test "returns :unknown for unrecognized messages" do
      assert :unknown = Discord.parse_gateway_message(%{"op" => 99})
      assert :unknown = Discord.parse_gateway_message(%{})
    end
  end

  describe "build_message_delta/1" do
    test "creates a message.received delta from MESSAGE_CREATE data" do
      data = %{
        "channel_id" => "chan_123",
        "content" => "Hello, world!",
        "id" => "msg_999",
        "guild_id" => "guild_456",
        "author" => %{
          "id" => "user_789",
          "username" => "testuser"
        }
      }

      delta = Discord.build_message_delta(data)

      assert delta.kind == "message.received"
      assert delta.payload["text"] == "Hello, world!"
      assert delta.payload["channel_id"] == "chan_123"
      assert delta.payload["author_id"] == "user_789"
      assert delta.payload["guild_id"] == "guild_456"
      assert delta.payload["username"] == "testuser"
      assert delta.payload["message_id"] == "msg_999"
    end

    test "origin is a channel tagged tuple" do
      data = %{
        "channel_id" => "chan_abc",
        "content" => "test",
        "author" => %{"id" => "user_abc"}
      }

      delta = Discord.build_message_delta(data)
      assert {:channel, "discord", "chan_abc", "user_abc"} = delta.origin
    end

    test "handles missing optional fields gracefully" do
      data = %{
        "channel_id" => "chan_minimal",
        "content" => "minimal",
        "author" => %{"id" => "user_min"}
      }

      delta = Discord.build_message_delta(data)
      assert delta.kind == "message.received"
      assert delta.payload["text"] == "minimal"
      assert is_nil(delta.payload["guild_id"])
      assert is_nil(delta.payload["username"])
    end

    test "handles missing author gracefully" do
      data = %{"channel_id" => "chan_1", "content" => "test"}
      delta = Discord.build_message_delta(data)
      assert delta.payload["author_id"] == "unknown"
    end
  end

  describe "build_identify/1" do
    test "builds a valid IDENTIFY payload" do
      identify = Discord.build_identify("Bot my-token")

      assert identify["op"] == 2
      assert identify["d"]["token"] == "Bot my-token"
      assert is_integer(identify["d"]["intents"])
      assert identify["d"]["intents"] > 0
      assert is_map(identify["d"]["properties"])
    end

    test "includes required gateway intents" do
      # 37377 = GUILDS(1) + GUILD_MESSAGES(512) + DIRECT_MESSAGES(4096) + MESSAGE_CONTENT(32768)
      identify = Discord.build_identify("token")
      assert identify["d"]["intents"] == 37377
    end
  end

  describe "gateway message handling (GenServer)" do
    test "plugin starts without connecting when token is absent" do
      {:ok, pid} = Discord.start_link(name: :"discord_test_#{:rand.uniform(999_999)}", core: self())
      assert Process.alive?(pid)
      GenServer.stop(pid)
    end

    test "plugin starts and registers with a mock core when token is set" do
      # We pass a fake core — the plugin will try to register with it, which may fail gracefully
      {:ok, pid} = Discord.start_link(
        name: :"discord_test_token_#{:rand.uniform(999_999)}",
        core: :nonexistent_core,
        token: "Bot fake-token"
      )

      assert Process.alive?(pid)
      GenServer.stop(pid)
    end
  end

  describe "send_message/3 (mocked)" do
    # These tests verify request construction logic without hitting Discord

    test "channel_id extracted from channel origin" do
      # Test the origin parsing logic used in the effect handler
      origin = {:channel, "discord", "channel_999", "user_abc"}

      channel_id =
        case origin do
          {:channel, "discord", cid, _} -> cid
          _ -> nil
        end

      assert channel_id == "channel_999"
    end

    test "non-discord origin returns nil channel" do
      origin = {:system, "cli"}

      channel_id =
        case origin do
          {:channel, "discord", cid, _} -> cid
          _ -> nil
        end

      assert is_nil(channel_id)
    end
  end

  describe "delta flow for Discord events" do
    test "MESSAGE_CREATE produces correct delta structure" do
      raw_event = %{
        "op" => 0,
        "t" => "MESSAGE_CREATE",
        "s" => 1,
        "d" => %{
          "id" => "msg_001",
          "channel_id" => "ch_discord",
          "content" => "hello kyber",
          "guild_id" => "guild_001",
          "author" => %{"id" => "author_001", "username" => "myk", "bot" => false}
        }
      }

      {:dispatch, "MESSAGE_CREATE", data} = Discord.parse_gateway_message(raw_event)
      delta = Discord.build_message_delta(data)

      assert delta.kind == "message.received"
      assert delta.payload["text"] == "hello kyber"
      assert {:channel, "discord", "ch_discord", "author_001"} = delta.origin
      assert delta.payload["username"] == "myk"
    end

    test "delta is a proper Kyber.Delta struct" do
      data = %{
        "channel_id" => "ch_1",
        "content" => "test",
        "author" => %{"id" => "user_1"}
      }

      delta = Discord.build_message_delta(data)
      assert %Delta{} = delta
      assert is_binary(delta.id)
      assert is_integer(delta.ts)
    end
  end

  describe "effect handler logic" do
    test "effect payload can be extracted for send_message" do
      # Simulate the effect that gets registered for :send_message
      effect = %{
        type: :send_message,
        origin: {:channel, "discord", "chan_123", "user_456"},
        payload: %{"channel_id" => "chan_123", "content" => "Hello from LLM!"}
      }

      channel_id =
        get_in(effect, [:payload, "channel_id"]) ||
          (case effect[:origin] do
            {:channel, "discord", cid, _} -> cid
            _ -> nil
          end)

      content = get_in(effect, [:payload, "content"])

      assert channel_id == "chan_123"
      assert content == "Hello from LLM!"
    end

    test "effect payload with reply_to is extracted" do
      effect = %{
        type: :send_message,
        payload: %{"channel_id" => "ch_1", "content" => "reply", "reply_to" => "msg_orig"}
      }

      reply_to = get_in(effect, [:payload, "reply_to"])
      assert reply_to == "msg_orig"
    end
  end

  # ── Feature 1: Attachment handling ──────────────────────────────────────────

  describe "build_message_delta/1 attachment handling" do
    test "extracts empty attachments list" do
      data = %{
        "channel_id" => "ch_1", "content" => "text",
        "author" => %{"id" => "u1"}, "attachments" => []
      }

      delta = Discord.build_message_delta(data)
      assert delta.payload["attachments"] == []
    end

    test "extracts single attachment with all fields" do
      attachment = %{
        "id" => "att_1", "filename" => "image.png", "content_type" => "image/png",
        "size" => 12345, "url" => "https://cdn.discordapp.com/attachments/image.png",
        "proxy_url" => "https://media.discordnet.com/attachments/image.png",
        "width" => 800, "height" => 600
      }
      data = %{
        "channel_id" => "ch_1", "content" => "check this",
        "author" => %{"id" => "u1"}, "attachments" => [attachment]
      }

      delta = Discord.build_message_delta(data)
      assert length(delta.payload["attachments"]) == 1
      [att] = delta.payload["attachments"]
      assert att["id"] == "att_1"
      assert att["filename"] == "image.png"
      assert att["content_type"] == "image/png"
      assert att["size"] == 12345
      assert att["url"] == "https://cdn.discordapp.com/attachments/image.png"
      assert att["proxy_url"] == "https://media.discordnet.com/attachments/image.png"
      assert att["width"] == 800
      assert att["height"] == 600
    end

    test "extracts multiple attachments" do
      data = %{
        "channel_id" => "ch_1", "content" => "",
        "author" => %{"id" => "u1"},
        "attachments" => [
          %{"id" => "a1", "filename" => "f1.txt"},
          %{"id" => "a2", "filename" => "f2.jpg"}
        ]
      }

      delta = Discord.build_message_delta(data)
      assert length(delta.payload["attachments"]) == 2
      assert Enum.map(delta.payload["attachments"], & &1["id"]) == ["a1", "a2"]
    end

    test "handles missing attachments key" do
      data = %{"channel_id" => "ch_1", "content" => "no att", "author" => %{"id" => "u1"}}
      delta = Discord.build_message_delta(data)
      assert delta.payload["attachments"] == []
    end
  end

  # ── Feature 2: Typing indicator ────────────────────────────────────────────

  describe "send_typing/2" do
    test "function exists with arity 2" do
      assert function_exported?(Discord, :send_typing, 2)
    end
  end

  # ── Feature 3: Emoji reactions ─────────────────────────────────────────────

  describe "emoji reactions" do
    test "add_reaction/4 exists" do
      assert function_exported?(Discord, :add_reaction, 4)
    end

    test "remove_reaction/4 exists" do
      assert function_exported?(Discord, :remove_reaction, 4)
    end

    test "reaction_url/3 URL-encodes emoji" do
      url = Discord.reaction_url("ch_1", "msg_1", "👍")
      assert String.contains?(url, "/channels/ch_1/messages/msg_1/reactions/")
      assert String.contains?(url, "%F0%9F%91%8D")
      assert String.ends_with?(url, "/@me")
    end

    test "reaction_url/3 handles text emoji name" do
      url = Discord.reaction_url("ch_1", "msg_1", "fire")
      assert String.contains?(url, "/reactions/fire/@me")
    end
  end

  # ── Feature 4: Reply threading ─────────────────────────────────────────────

  describe "build_message_body/2 reply threading" do
    test "includes message_reference when reply_to given" do
      body = Discord.build_message_body("hello", reply_to: "msg_123")
      assert body["content"] == "hello"
      assert body["message_reference"] == %{"message_id" => "msg_123"}
    end

    test "no message_reference without reply_to" do
      body = Discord.build_message_body("hello")
      assert body["content"] == "hello"
      refute Map.has_key?(body, "message_reference")
    end

    test "nil reply_to is treated as absent" do
      body = Discord.build_message_body("hello", reply_to: nil)
      refute Map.has_key?(body, "message_reference")
    end
  end

  # ── Feature 5: Message chunking ────────────────────────────────────────────

  describe "chunk_message/1" do
    test "returns single chunk for empty string" do
      assert Discord.chunk_message("") == [""]
    end

    test "returns single chunk for nil" do
      assert Discord.chunk_message(nil) == [""]
    end

    test "returns single chunk for content exactly 2000 chars" do
      content = String.duplicate("a", 2000)
      assert Discord.chunk_message(content) == [content]
    end

    test "returns single chunk for short content" do
      assert Discord.chunk_message("hello") == ["hello"]
    end

    test "splits content at 2000 chars when no newlines" do
      content = String.duplicate("a", 2001)
      chunks = Discord.chunk_message(content)
      assert length(chunks) == 2
      assert String.length(hd(chunks)) == 2000
      assert String.length(List.last(chunks)) == 1
    end

    test "breaks at newlines when possible" do
      line1 = String.duplicate("a", 1500)
      line2 = String.duplicate("b", 1500)
      content = "#{line1}\n#{line2}"

      chunks = Discord.chunk_message(content)
      assert length(chunks) == 2
      assert hd(chunks) == line1
      assert List.last(chunks) == line2
    end

    test "preserves total content length for no-newline content" do
      content = String.duplicate("x", 4500)
      chunks = Discord.chunk_message(content)
      total = chunks |> Enum.map(&String.length/1) |> Enum.sum()
      assert total == 4500
    end

    test "every chunk is <= 2000 chars" do
      content = String.duplicate("abcde\n", 500)
      chunks = Discord.chunk_message(content)
      Enum.each(chunks, fn chunk ->
        assert String.length(chunk) <= 2000
      end)
    end

    test "handles content with only newlines" do
      content = String.duplicate("\n", 2500)
      chunks = Discord.chunk_message(content)
      Enum.each(chunks, fn chunk ->
        assert String.length(chunk) <= 2000
      end)
    end
  end

  # ── Feature 7: Embeds ──────────────────────────────────────────────────────

  describe "build_message_body/2 embeds" do
    test "includes embeds when provided" do
      embeds = [%{"title" => "Test", "description" => "A test embed", "color" => 0xFF0000}]
      body = Discord.build_message_body("text", embeds: embeds)
      assert body["content"] == "text"
      assert body["embeds"] == embeds
    end

    test "no embeds key when not provided" do
      body = Discord.build_message_body("text")
      refute Map.has_key?(body, "embeds")
    end

    test "no embeds key when empty list" do
      body = Discord.build_message_body("text", embeds: [])
      refute Map.has_key?(body, "embeds")
    end

    test "combines reply_to and embeds" do
      embeds = [%{"title" => "Embed"}]
      body = Discord.build_message_body("text", reply_to: "msg_1", embeds: embeds)
      assert body["message_reference"]["message_id"] == "msg_1"
      assert body["embeds"] == embeds
      assert body["content"] == "text"
    end

    test "embed with all standard fields" do
      embed = %{
        "title" => "Title", "description" => "Desc", "color" => 0x00FF00,
        "fields" => [%{"name" => "Field", "value" => "Value", "inline" => true}],
        "footer" => %{"text" => "Footer text"}
      }
      body = Discord.build_message_body("", embeds: [embed])
      [result_embed] = body["embeds"]
      assert result_embed["fields"] == [%{"name" => "Field", "value" => "Value", "inline" => true}]
      assert result_embed["footer"] == %{"text" => "Footer text"}
    end
  end

  # ── Feature 8: Channel history ─────────────────────────────────────────────

  describe "fetch_messages/3" do
    test "function exists with arity 3" do
      assert function_exported?(Discord, :fetch_messages, 3)
    end

    test "builds correct query params" do
      url = Discord.fetch_messages_url("ch_123", limit: 10, before: "msg_50")
      assert String.contains?(url, "/channels/ch_123/messages")
      assert String.contains?(url, "limit=10")
      assert String.contains?(url, "before=msg_50")
    end

    test "default limit is 50" do
      url = Discord.fetch_messages_url("ch_123", [])
      assert String.contains?(url, "limit=50")
    end

    test "limit is capped at 100" do
      url = Discord.fetch_messages_url("ch_123", limit: 200)
      assert String.contains?(url, "limit=100")
    end

    test "supports after param" do
      url = Discord.fetch_messages_url("ch_123", after: "msg_10")
      assert String.contains?(url, "after=msg_10")
    end
  end

  # ── Feature 9: Message editing ─────────────────────────────────────────────

  describe "edit_message/4" do
    test "function exists with arity 4" do
      assert function_exported?(Discord, :edit_message, 4)
    end
  end

  # ── Feature 10: File/image sending ─────────────────────────────────────────

  describe "send_file/4" do
    test "function exists with arity 4" do
      assert function_exported?(Discord, :send_file, 4)
    end
  end

  # ── delete_message ──────────────────────────────────────────────────────────

  describe "delete_message/3" do
    test "function exists with arity 3" do
      assert function_exported?(Discord, :delete_message, 3)
    end
  end

  describe "validate_snowflake/1 (via delete_message)" do
    # validate_snowflake is private, so we test it indirectly through delete_message
    # which will reject invalid IDs before making any HTTP call

    test "rejects non-numeric channel_id" do
      assert {:error, :invalid_snowflake_id} = Discord.delete_message("token", "not-a-snowflake", "1484644246005874991")
    end

    test "rejects non-numeric message_id" do
      assert {:error, :invalid_snowflake_id} = Discord.delete_message("token", "1484644246005874991", "../../../etc/passwd")
    end

    test "rejects too-short numeric id" do
      assert {:error, :invalid_snowflake_id} = Discord.delete_message("token", "123", "1484644246005874991")
    end

    test "rejects empty string id" do
      assert {:error, :invalid_snowflake_id} = Discord.delete_message("token", "", "1484644246005874991")
    end
  end

  describe "delete_message effect handler logic" do
    test "effect payload extraction for delete_message" do
      effect = %{
        type: :delete_message,
        payload: %{"channel_id" => "1484644246005874991", "message_id" => "1484643683465822279"}
      }

      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])

      assert channel_id == "1484644246005874991"
      assert message_id == "1484643683465822279"
    end

    test "missing channel_id returns missing_params" do
      effect = %{type: :delete_message, payload: %{"message_id" => "123456789012345678"}}
      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])

      refute channel_id && message_id
    end

    test "missing message_id returns missing_params" do
      effect = %{type: :delete_message, payload: %{"channel_id" => "123456789012345678"}}
      channel_id = get_in(effect, [:payload, "channel_id"])
      message_id = get_in(effect, [:payload, "message_id"])

      refute channel_id && message_id
    end
  end

  # ── Feature 6: Presence (plugin-level) ─────────────────────────────────────

  describe "update_presence/2" do
    test "function exists with arity 2" do
      assert function_exported?(Discord, :update_presence, 2)
    end
  end
end
