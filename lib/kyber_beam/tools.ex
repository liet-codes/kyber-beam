defmodule Kyber.Tools do
  @moduledoc """
  Tool definitions for Stilgar's tool use capability.

  Each tool is an Anthropic-format tool definition map. The executor
  registry maps tool names to handler functions in `Kyber.ToolExecutor`.

  Phase 4 tools: read_file, write_file, edit_file, exec, list_dir
  """

  @tools [
    %{
      "name" => "read_file",
      "description" => "Read the contents of a file at the given path.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Absolute or ~-relative file path"
          },
          "offset" => %{
            "type" => "integer",
            "description" => "Line number to start reading from (1-indexed)"
          },
          "limit" => %{
            "type" => "integer",
            "description" => "Max lines to return"
          }
        },
        "required" => ["path"]
      }
    },
    %{
      "name" => "write_file",
      "description" => "Write content to a file, creating it and any missing parent directories if needed.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute or ~-relative file path"},
          "content" => %{"type" => "string", "description" => "Content to write"}
        },
        "required" => ["path", "content"]
      }
    },
    %{
      "name" => "edit_file",
      "description" => "Replace an exact string in a file with new text. Fails if old_string is not found.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "File path"},
          "old_string" => %{"type" => "string", "description" => "Exact text to find"},
          "new_string" => %{"type" => "string", "description" => "Replacement text"}
        },
        "required" => ["path", "old_string", "new_string"]
      }
    },
    %{
      "name" => "exec",
      "description" => "Run a shell command. Returns stdout+stderr and exit code.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "command" => %{
            "type" => "string",
            "description" => "Shell command to run (via sh -c)"
          },
          "workdir" => %{
            "type" => "string",
            "description" => "Working directory (defaults to HOME)"
          },
          "timeout_ms" => %{
            "type" => "integer",
            "description" => "Timeout in milliseconds (default 30000)"
          }
        },
        "required" => ["command"]
      }
    },
    %{
      "name" => "list_dir",
      "description" => "List files and directories at a path. Directories are shown with a trailing /.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{"type" => "string", "description" => "Absolute or ~-relative path"}
        },
        "required" => ["path"]
      }
    }
  ]

  @doc "Return all tool definitions in Anthropic format."
  @spec definitions() :: [map()]
  def definitions, do: @tools

  @doc "Return all tool names."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1["name"])
end
