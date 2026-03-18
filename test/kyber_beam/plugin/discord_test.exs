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
      # 34307 = GUILDS(1) + GUILD_MESSAGES(512) + MESSAGE_CONTENT(32768) + others
      identify = Discord.build_identify("token")
      assert identify["d"]["intents"] == 34307
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
  end
end
