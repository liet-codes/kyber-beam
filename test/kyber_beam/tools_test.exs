defmodule Kyber.ToolsTest do
  use ExUnit.Case, async: true

  alias Kyber.Tools

  describe "definitions/0" do
    test "returns a list of tool maps" do
      defs = Tools.definitions()
      assert is_list(defs)
      assert length(defs) > 0
    end

    test "each tool has required Anthropic format fields" do
      for tool <- Tools.definitions() do
        assert is_binary(tool["name"]), "tool name must be a string"

        # Anthropic computer use tools use a special format with "type" instead
        # of "description" + "input_schema" (e.g. type: "computer_20251124")
        if String.starts_with?(tool["type"] || "", "computer_") do
          assert is_binary(tool["type"]), "computer use tool type must be a string"
          assert is_integer(tool["display_width_px"]), "display_width_px must be an integer"
          assert is_integer(tool["display_height_px"]), "display_height_px must be an integer"
        else
          assert is_binary(tool["description"]), "tool description must be a string"
          assert is_map(tool["input_schema"]), "tool input_schema must be a map"
          assert tool["input_schema"]["type"] == "object"
          assert is_map(tool["input_schema"]["properties"])
        end
      end
    end

    test "includes all Phase 4 tools" do
      names = Tools.names()
      assert "read_file" in names
      assert "write_file" in names
      assert "edit_file" in names
      assert "exec" in names
      assert "list_dir" in names
    end

    test "includes all Phase 5 tools" do
      names = Tools.names()
      assert "memory_read" in names
      assert "memory_write" in names
      assert "memory_list" in names
      assert "web_fetch" in names
    end

    test "memory_read has required path property" do
      tool = Enum.find(Tools.definitions(), &(&1["name"] == "memory_read"))
      assert "path" in tool["input_schema"]["required"]
    end

    test "memory_write requires path and content" do
      tool = Enum.find(Tools.definitions(), &(&1["name"] == "memory_write"))
      assert "path" in tool["input_schema"]["required"]
      assert "content" in tool["input_schema"]["required"]
    end

    test "web_fetch requires url" do
      tool = Enum.find(Tools.definitions(), &(&1["name"] == "web_fetch"))
      assert "url" in tool["input_schema"]["required"]
    end

    test "read_file has required path property" do
      read_file = Enum.find(Tools.definitions(), &(&1["name"] == "read_file"))
      assert "path" in read_file["input_schema"]["required"]
      assert Map.has_key?(read_file["input_schema"]["properties"], "path")
    end

    test "write_file requires path and content" do
      write_file = Enum.find(Tools.definitions(), &(&1["name"] == "write_file"))
      assert "path" in write_file["input_schema"]["required"]
      assert "content" in write_file["input_schema"]["required"]
    end

    test "exec requires command" do
      exec_tool = Enum.find(Tools.definitions(), &(&1["name"] == "exec"))
      assert "command" in exec_tool["input_schema"]["required"]
    end
  end

  describe "names/0" do
    test "returns list of strings" do
      names = Tools.names()
      assert is_list(names)
      assert Enum.all?(names, &is_binary/1)
    end

    test "count matches definitions count" do
      assert length(Tools.names()) == length(Tools.definitions())
    end
  end
end
