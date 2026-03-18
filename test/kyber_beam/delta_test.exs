defmodule Kyber.DeltaTest do
  use ExUnit.Case, async: true

  alias Kyber.Delta
  alias Kyber.Delta.Origin

  describe "Kyber.Delta.new/4" do
    test "creates a delta with generated id" do
      delta = Delta.new("message.received", %{text: "hello"})
      assert is_binary(delta.id)
      assert byte_size(delta.id) > 0
    end

    test "sets kind correctly" do
      delta = Delta.new("error.route", %{})
      assert delta.kind == "error.route"
    end

    test "sets payload" do
      delta = Delta.new("plugin.loaded", %{name: "my_plugin"})
      assert delta.payload == %{name: "my_plugin"}
    end

    test "sets origin" do
      origin = {:human, "user_42"}
      delta = Delta.new("message.received", %{}, origin)
      assert delta.origin == {:human, "user_42"}
    end

    test "sets parent_id" do
      delta = Delta.new("message.received", %{}, {:system, "test"}, "parent-123")
      assert delta.parent_id == "parent-123"
    end

    test "defaults parent_id to nil" do
      delta = Delta.new("message.received")
      assert is_nil(delta.parent_id)
    end

    test "sets ts as integer millisecond timestamp" do
      before = System.system_time(:millisecond)
      delta = Delta.new("message.received")
      after_ts = System.system_time(:millisecond)
      assert delta.ts >= before
      assert delta.ts <= after_ts
    end

    test "generates unique ids" do
      d1 = Delta.new("message.received")
      d2 = Delta.new("message.received")
      refute d1.id == d2.id
    end
  end

  describe "Kyber.Delta to_map/from_map" do
    test "round-trips through to_map/from_map" do
      original = Delta.new("message.received", %{"text" => "hello"}, {:human, "u1"}, "pid-0")
      map = Delta.to_map(original)
      restored = Delta.from_map(map)

      assert restored.id == original.id
      assert restored.ts == original.ts
      assert restored.kind == original.kind
      assert restored.parent_id == original.parent_id
      assert restored.payload == original.payload
    end

    test "to_map returns string-keyed map" do
      delta = Delta.new("test.event", %{})
      map = Delta.to_map(delta)
      assert Map.has_key?(map, "id")
      assert Map.has_key?(map, "kind")
      assert Map.has_key?(map, "origin")
      assert Map.has_key?(map, "ts")
      assert Map.has_key?(map, "payload")
      assert Map.has_key?(map, "parent_id")
    end

    test "from_map handles nil parent_id" do
      delta = Delta.new("test.event")
      map = Delta.to_map(delta)
      restored = Delta.from_map(map)
      assert is_nil(restored.parent_id)
    end
  end

  describe "Kyber.Delta.Origin" do
    test "serializes :channel origin" do
      origin = {:channel, "discord", "chat-1", "user-99"}
      map = Origin.serialize(origin)
      assert map["type"] == "channel"
      assert map["channel"] == "discord"
      assert map["chat_id"] == "chat-1"
      assert map["sender_id"] == "user-99"
    end

    test "serializes :cron origin" do
      origin = {:cron, "*/5 * * * *"}
      map = Origin.serialize(origin)
      assert map["type"] == "cron"
      assert map["schedule"] == "*/5 * * * *"
    end

    test "serializes :subagent origin" do
      origin = {:subagent, "parent-delta-abc"}
      map = Origin.serialize(origin)
      assert map["type"] == "subagent"
      assert map["parent_delta_id"] == "parent-delta-abc"
    end

    test "serializes :tool origin" do
      origin = {:tool, "web_search"}
      map = Origin.serialize(origin)
      assert map["type"] == "tool"
      assert map["tool"] == "web_search"
    end

    test "serializes :human origin" do
      origin = {:human, "myk-42"}
      map = Origin.serialize(origin)
      assert map["type"] == "human"
      assert map["user_id"] == "myk-42"
    end

    test "serializes :system origin" do
      origin = {:system, "startup"}
      map = Origin.serialize(origin)
      assert map["type"] == "system"
      assert map["reason"] == "startup"
    end

    test "round-trips all origin types" do
      origins = [
        {:channel, "slack", "c1", "s1"},
        {:cron, "0 9 * * *"},
        {:subagent, "delta-001"},
        {:tool, "file_read"},
        {:human, "user-1"},
        {:system, "init"}
      ]

      for origin <- origins do
        assert Origin.deserialize(Origin.serialize(origin)) == origin
      end
    end

    test "deserialize falls back to system for unknown" do
      result = Origin.deserialize(%{"type" => "unknown_thing"})
      assert elem(result, 0) == :system
    end
  end
end
