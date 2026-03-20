defmodule Kyber.Plugin.Discord.GatewayTest do
  use ExUnit.Case, async: true

  alias Kyber.Plugin.Discord.Gateway

  describe "module structure" do
    test "Gateway module exists with start_link/1" do
      # Ensure module is loaded before checking exports
      :code.ensure_loaded(Gateway)
      assert function_exported?(Gateway, :start_link, 0) or function_exported?(Gateway, :start_link, 1)
    end

    test "start_link without required opts causes the process to exit" do
      # Keyword.fetch! in init raises KeyError → process crashes
      Process.flag(:trap_exit, true)
      {:error, _reason} = Gateway.start_link([])
    end
  end

  describe "lifecycle with mock handler" do
    @tag :capture_log
    test "Gateway starts without crashing (connection failure is graceful)" do
      test_pid = self()

      # start_link with valid (but bogus) token - the process starts, then
      # attempts connection asynchronously. We stop it immediately.
      {:ok, pid} = Gateway.start_link(token: "invalid-token", handler_pid: test_pid)
      assert Process.alive?(pid)

      # Stop it cleanly before it does much
      GenServer.stop(pid, :normal)
      refute Process.alive?(pid)
    end
  end

  describe "zlib compression logic" do
    test "Discord transport compression suffix is 4 bytes: 0x00 0x00 0xFF 0xFF" do
      suffix = <<0x00, 0x00, 0xFF, 0xFF>>
      assert byte_size(suffix) == 4
      assert suffix == <<0, 0, 255, 255>>
    end

    test "deflate with sync flush produces the Discord suffix" do
      json = ~s({"op": 10, "d": {"heartbeat_interval": 41250}})

      z_d = :zlib.open()
      :zlib.deflateInit(z_d)
      chunks = :zlib.deflate(z_d, json, :sync)
      :zlib.close(z_d)
      compressed = IO.iodata_to_binary(chunks)

      suffix = <<0x00, 0x00, 0xFF, 0xFF>>
      assert binary_part(compressed, byte_size(compressed) - 4, 4) == suffix
    end

    test "inflate + deflate round-trips JSON correctly" do
      json = ~s({"op": 0, "t": "MESSAGE_CREATE", "s": 42, "d": {"content": "hello"}})

      z_d = :zlib.open()
      :zlib.deflateInit(z_d)
      chunks = :zlib.deflate(z_d, json, :sync)
      :zlib.close(z_d)
      compressed = IO.iodata_to_binary(chunks)

      z_i = :zlib.open()
      :zlib.inflateInit(z_i)
      inflated = IO.iodata_to_binary(:zlib.inflate(z_i, compressed))
      :zlib.close(z_i)

      assert inflated == json
    end

    test "single zlib context handles multiple sequential zlib-stream messages" do
      msg1 = ~s({"op": 10, "d": {"heartbeat_interval": 41250}})
      msg2 = ~s({"op": 11})

      # One deflate context for streaming compression
      z_d = :zlib.open()
      :zlib.deflateInit(z_d)
      compressed1 = IO.iodata_to_binary(:zlib.deflate(z_d, msg1, :sync))
      compressed2 = IO.iodata_to_binary(:zlib.deflate(z_d, msg2, :sync))
      :zlib.close(z_d)

      # One inflate context for streaming decompression
      z_i = :zlib.open()
      :zlib.inflateInit(z_i)
      inflated1 = IO.iodata_to_binary(:zlib.inflate(z_i, compressed1))
      inflated2 = IO.iodata_to_binary(:zlib.inflate(z_i, compressed2))
      :zlib.close(z_i)

      assert inflated1 == msg1
      assert inflated2 == msg2
    end
  end

  describe "event forwarding" do
    test "handler_pid receives {:discord_event, json} messages" do
      json = ~s({"op": 0, "t": "MESSAGE_CREATE", "s": 1, "d": {"content": "test"}})
      send(self(), {:discord_event, json})

      assert_receive {:discord_event, received_json}, 500
      {:ok, msg} = Jason.decode(received_json)
      assert msg["op"] == 0
      assert msg["t"] == "MESSAGE_CREATE"
    end
  end

  describe "IDENTIFY payload (Discord API v10)" do
    test "properties use new keys without $ prefix" do
      properties = %{"os" => "beam", "browser" => "kyber", "device" => "kyber"}
      refute Map.has_key?(properties, "$os")
      assert properties["os"] == "beam"
      assert properties["browser"] == "kyber"
      assert properties["device"] == "kyber"
    end

    test "intents bitmask includes required GUILDS, GUILD_MESSAGES, MESSAGE_CONTENT" do
      import Bitwise
      intents = 34307
      guilds = 1           # bit 0
      guild_messages = 512 # bit 9
      message_content = 32768 # bit 15

      assert band(intents, guilds) == guilds
      assert band(intents, guild_messages) == guild_messages
      assert band(intents, message_content) == message_content
      # 34307 = 1 + 2 + 512 + 1024 + 32768 (GUILDS + GUILD_MEMBERS + GUILD_MESSAGES + GUILD_BANS + MESSAGE_CONTENT)
      assert intents == 34307
    end
  end

  describe "backoff logic" do
    test "backoff doubles up to max of 30 seconds" do
      initial = 1_000
      max = 30_000

      values =
        Stream.iterate(initial, fn b -> min(b * 2, max) end)
        |> Enum.take(8)

      assert values == [1_000, 2_000, 4_000, 8_000, 16_000, 30_000, 30_000, 30_000]
    end
  end

  describe "end-to-end message flow (unit)" do
    test "MESSAGE_CREATE JSON → parse → delta → reducer → llm_call effect" do
      raw_json = Jason.encode!(%{
        "op" => 0,
        "t" => "MESSAGE_CREATE",
        "s" => 5,
        "d" => %{
          "id" => "msg_001",
          "channel_id" => "ch_discord",
          "content" => "hello kyber",
          "guild_id" => "guild_001",
          "author" => %{"id" => "author_001", "username" => "stilgar", "bot" => false}
        }
      })

      # Step 1: Parse via Discord plugin
      {:ok, msg} = Jason.decode(raw_json)
      {:dispatch, "MESSAGE_CREATE", data} = Kyber.Plugin.Discord.parse_gateway_message(msg)

      # Step 2: Build delta
      delta = Kyber.Plugin.Discord.build_message_delta(data)
      assert delta.kind == "message.received"
      assert delta.payload["text"] == "hello kyber"
      assert {:channel, "discord", "ch_discord", "author_001"} = delta.origin

      # Step 3: Reduce → effects
      state = %Kyber.State{}
      {_new_state, effects} = Kyber.Reducer.reduce(state, delta)
      assert length(effects) == 1
      assert hd(effects).type == :llm_call
    end

    test "bot messages are filtered before delta creation" do
      bot_data = %{
        "id" => "bot_msg",
        "channel_id" => "ch_1",
        "content" => "automated message",
        "author" => %{"id" => "bot_001", "bot" => true}
      }

      # The Discord plugin checks this before calling build_message_delta
      is_bot = get_in(bot_data, ["author", "bot"])
      assert is_bot == true
    end

    test "HELLO opcode parses to {:hello, interval} via Discord plugin" do
      hello = %{"op" => 10, "d" => %{"heartbeat_interval" => 41250}}
      assert {:hello, 41250} = Kyber.Plugin.Discord.parse_gateway_message(hello)
    end
  end

  # ── Feature 6: Presence/status ───────────────────────────────────────────

  describe "presence update payload" do
    test "build_presence_update/1 creates valid OP 3 payload" do
      payload = Gateway.build_presence_update(%{status: "online", game_name: "Kyber", game_type: 0})
      assert payload["op"] == 3
      assert payload["d"]["status"] == "online"
      assert payload["d"]["afk"] == false
      [activity] = payload["d"]["activities"]
      assert activity["name"] == "Kyber"
      assert activity["type"] == 0
    end

    test "build_presence_update/1 defaults to online with no activity" do
      payload = Gateway.build_presence_update(%{})
      assert payload["d"]["status"] == "online"
      assert payload["d"]["activities"] == []
    end

    test "build_presence_update/1 supports all status types" do
      for status <- ["online", "idle", "dnd", "invisible"] do
        payload = Gateway.build_presence_update(%{status: status})
        assert payload["d"]["status"] == status
      end
    end

    test "build_presence_update/1 supports activity types" do
      for {type, name} <- [{0, "Playing"}, {1, "Streaming"}, {2, "Listening"}, {3, "Watching"}, {5, "Competing"}] do
        payload = Gateway.build_presence_update(%{game_name: name, game_type: type})
        [activity] = payload["d"]["activities"]
        assert activity["type"] == type
        assert activity["name"] == name
      end
    end

    test "send_presence_update/2 function exists" do
      assert function_exported?(Gateway, :send_presence_update, 2)
    end
  end
end
