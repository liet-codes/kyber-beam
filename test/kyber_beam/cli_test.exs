defmodule Kyber.CLITest do
  use ExUnit.Case, async: true

  alias Kyber.{CLI, Delta, State}

  describe "parse_args/1" do
    test "parses key-value pairs" do
      {flags, opts} = CLI.parse_args(["--kind", "message.received"])
      assert opts["kind"] == "message.received"
      assert flags == []
    end

    test "parses multiple key-value pairs" do
      args = ["--kind", "msg.received", "--limit", "10"]
      {flags, opts} = CLI.parse_args(args)
      assert opts["kind"] == "msg.received"
      assert opts["limit"] == "10"
      assert flags == []
    end

    test "parses flags (no value after)" do
      {flags, opts} = CLI.parse_args(["--verbose", "--dry-run"])
      assert "--verbose" in flags
      assert "--dry-run" in flags
      assert opts == %{}
    end

    test "parses mixed flags and key-value pairs" do
      args = ["--kind", "test", "--verbose", "--limit", "5"]
      {flags, opts} = CLI.parse_args(args)
      assert "--verbose" in flags
      assert opts["kind"] == "test"
      assert opts["limit"] == "5"
    end

    test "handles empty args" do
      assert {[], %{}} = CLI.parse_args([])
    end

    test "payload with JSON value" do
      args = ["--payload", ~s({"text":"hello world"})]
      {_flags, opts} = CLI.parse_args(args)
      assert opts["payload"] == ~s({"text":"hello world"})
    end
  end

  describe "format_delta/1" do
    test "formats a delta with all fields" do
      delta = Delta.new("message.received", %{"text" => "hi"}, {:human, "user_1"})
      output = CLI.format_delta(delta)

      assert String.contains?(output, "message.received")
      assert String.contains?(output, delta.id)
      assert String.contains?(output, "hi")
    end

    test "includes origin info" do
      delta = Delta.new("test", %{}, {:channel, "discord", "ch_1", "u_1"})
      output = CLI.format_delta(delta)
      assert String.contains?(output, "discord")
      assert String.contains?(output, "ch_1")
    end

    test "shows parent_id when present" do
      parent = Delta.new("parent", %{})
      child = Delta.new("child", %{}, {:system, "test"}, parent.id)
      output = CLI.format_delta(child)
      assert String.contains?(output, parent.id)
    end

    test "shows dash for nil parent_id" do
      delta = Delta.new("test", %{})
      output = CLI.format_delta(delta)
      assert String.contains?(output, "—")
    end

    test "formats payload as indented JSON" do
      delta = Delta.new("test", %{"nested" => %{"key" => "value"}})
      output = CLI.format_delta(delta)
      assert String.contains?(output, "nested")
    end
  end

  describe "format_state/3" do
    test "shows no plugins when empty" do
      state = %State{}
      output = CLI.format_state(state, [], [])
      assert String.contains?(output, "(none)")
    end

    test "lists plugins" do
      state = %State{}
      output = CLI.format_state(state, ["llm", "discord"], [])
      assert String.contains?(output, "llm")
      assert String.contains?(output, "discord")
    end

    test "lists sessions" do
      state = %State{}
      output = CLI.format_state(state, [], ["chat_1", "chat_2"])
      assert String.contains?(output, "chat_1")
      assert String.contains?(output, "chat_2")
    end

    test "lists errors from state" do
      state = %State{errors: [%{delta_id: "abc123", payload: %{"msg" => "oops"}}]}
      output = CLI.format_state(state, [], [])
      assert String.contains?(output, "abc123")
    end

    test "shows counts in headers" do
      state = %State{}
      output = CLI.format_state(state, ["llm"], ["s1", "s2"])
      assert String.contains?(output, "Plugins (1)")
      assert String.contains?(output, "Sessions (2)")
    end
  end

  describe "decode_json/1" do
    test "decodes valid JSON object" do
      assert {:ok, %{"key" => "value"}} = CLI.decode_json(~s({"key":"value"}))
    end

    test "decodes complex nested JSON" do
      json = ~s({"text":"hi","nested":{"a":1}})
      assert {:ok, map} = CLI.decode_json(json)
      assert map["text"] == "hi"
      assert map["nested"]["a"] == 1
    end

    test "returns error for invalid JSON" do
      assert {:error, msg} = CLI.decode_json("not json")
      assert is_binary(msg)
      assert String.contains?(msg, "invalid JSON")
    end

    test "returns error for JSON array (not object)" do
      assert {:error, msg} = CLI.decode_json("[1,2,3]")
      assert String.contains?(msg, "JSON object")
    end

    test "returns error for JSON string" do
      assert {:error, msg} = CLI.decode_json(~s("just a string"))
      assert String.contains?(msg, "JSON object")
    end
  end
end
