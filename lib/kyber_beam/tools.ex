defmodule Kyber.Tools do
  @moduledoc """
  Tool definitions for Stilgar's tool use capability.

  Each tool is an Anthropic-format tool definition map. The executor
  registry maps tool names to handler functions in `Kyber.ToolExecutor`.

  Phase 4 tools: read_file, write_file, edit_file, exec, list_dir
  Phase 5 tools: memory_read, memory_write, memory_list, web_fetch
  Phase 6 tools: beam_memory, beam_system, beam_processes, beam_inspect_process,
                 beam_genserver_state, beam_supervision_tree, beam_ets, beam_ets_inspect,
                 beam_deltas, beam_queue_health, beam_gc, beam_reload_module,
                 beam_io_stats, beam_ports
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
    },
    %{
      "name" => "memory_read",
      "description" =>
        "Read a note from the knowledge vault by path (e.g. 'memory/2026-03-18.md', 'identity/SOUL.md'). Returns full note content including frontmatter.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path relative to vault root (e.g. 'memory/2026-03-18.md')"
          },
          "tier" => %{
            "type" => "string",
            "enum" => ["l0", "l1", "l2"],
            "description" => "l0=title+tags only, l1=frontmatter+first paragraph, l2=full content (default)"
          }
        },
        "required" => ["path"]
      }
    },
    %{
      "name" => "memory_write",
      "description" => "Write or update a note in the knowledge vault. Creates the file if it doesn't exist.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path relative to vault root (e.g. 'memory/2026-03-19.md')"
          },
          "content" => %{
            "type" => "string",
            "description" => "Full file content to write (include YAML frontmatter if needed)"
          }
        },
        "required" => ["path", "content"]
      }
    },
    %{
      "name" => "memory_list",
      "description" => "List files in the knowledge vault. Returns relative paths of all markdown notes.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "subdir" => %{
            "type" => "string",
            "description" => "Optional subdirectory to list (e.g. 'memory', 'identity'). Lists all if omitted."
          }
        }
      }
    },
    %{
      "name" => "memory_pool_list",
      "description" =>
        "List all memories in the memory pool with their salience scores, tags, and pin status. Use this to understand what you remember and manage your memory.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{}
      }
    },
    %{
      "name" => "memory_pin",
      "description" =>
        "Pin a memory so it never decays or gets garbage collected. Use for things you decide are permanently important. Requires the memory ID from memory_pool_list.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "memory_id" => %{
            "type" => "string",
            "description" => "The ID of the memory to pin"
          }
        },
        "required" => ["memory_id"]
      }
    },
    %{
      "name" => "memory_unpin",
      "description" =>
        "Unpin a memory, allowing it to decay naturally. Use when something is no longer permanently important.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "memory_id" => %{
            "type" => "string",
            "description" => "The ID of the memory to unpin"
          }
        },
        "required" => ["memory_id"]
      }
    },
    %{
      "name" => "web_fetch",
      "description" =>
        "Fetch a URL and return its text content. Useful for reading documentation, articles, or any web resource. Response is truncated to 50KB.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "Full URL to fetch (must start with http:// or https://)"
          }
        },
        "required" => ["url"]
      }
    },

    # ── Phase 6: BEAM Introspection (unique to kyber-beam) ──────────────────

    %{
      "name" => "beam_memory",
      "description" =>
        "BEAM VM memory breakdown: total, processes, ETS, binary, code, atom. All in MB.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "beam_system",
      "description" =>
        "BEAM system info: scheduler count, process/atom/port counts, uptime, OTP version.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "beam_processes",
      "description" =>
        "Top processes by memory usage. Returns pid, name, memory_kb, message_queue_len, reductions.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "limit" => %{
            "type" => "integer",
            "description" => "Max processes to return (default 20)"
          }
        }
      }
    },
    %{
      "name" => "beam_inspect_process",
      "description" =>
        "Inspect a named BEAM process: memory, queue length, status, current function.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "Registered process name, e.g. 'Kyber.Plugin.LLM'"
          }
        },
        "required" => ["name"]
      }
    },
    %{
      "name" => "beam_genserver_state",
      "description" =>
        "Inspect a GenServer's internal state via :sys.get_state/1. Works on any named GenServer including Kyber plugins.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "name" => %{
            "type" => "string",
            "description" => "GenServer registered name, e.g. 'Kyber.Session'"
          }
        },
        "required" => ["name"]
      }
    },
    %{
      "name" => "beam_supervision_tree",
      "description" =>
        "Walk the supervision tree of a supervisor. Shows children counts, PIDs, types.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "supervisor" => %{
            "type" => "string",
            "description" => "Supervisor name, e.g. 'Kyber.Core' or 'KyberBeam.Supervisor'"
          },
          "depth" => %{
            "type" => "integer",
            "description" => "Recursion depth (default 2)"
          }
        },
        "required" => ["supervisor"]
      }
    },
    %{
      "name" => "beam_ets",
      "description" =>
        "ETS table summary: all tables with name, row count, memory usage, type.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "beam_ets_inspect",
      "description" => "Inspect a specific ETS table: size, memory, sample keys.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "table" => %{
            "type" => "string",
            "description" => "Table name atom, e.g. 'Kyber.Session.Sessions'"
          }
        },
        "required" => ["table"]
      }
    },
    %{
      "name" => "beam_deltas",
      "description" =>
        "Delta store stats: total delta count, breakdown by kind, file size.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "beam_queue_health",
      "description" =>
        "Find processes with backed-up message queues (default threshold: 5). Detects backpressure.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "threshold" => %{
            "type" => "integer",
            "description" => "Min queue length to report (default 5)"
          }
        }
      }
    },
    %{
      "name" => "beam_gc",
      "description" =>
        "Trigger garbage collection on a named process or all processes. Returns memory freed.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "target" => %{
            "type" => "string",
            "description" => "Process name or 'all'"
          }
        },
        "required" => ["target"]
      }
    },
    %{
      "name" => "beam_reload_module",
      "description" => "Hot-reload an Elixir module without restarting the VM.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "module" => %{
            "type" => "string",
            "description" => "Module name, e.g. 'Kyber.Reducer'"
          }
        },
        "required" => ["module"]
      }
    },
    %{
      "name" => "beam_io_stats",
      "description" => "VM-level I/O statistics: total bytes in/out since start.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    },
    %{
      "name" => "beam_ports",
      "description" =>
        "Port/socket inspection: active ports, driver names, connected processes.",
      "input_schema" => %{"type" => "object", "properties" => %{}}
    }
  ]

  @doc "Return all tool definitions in Anthropic format."
  @spec definitions() :: [map()]
  def definitions, do: @tools

  @doc "Return all tool names."
  @spec names() :: [String.t()]
  def names, do: Enum.map(@tools, & &1["name"])
end
