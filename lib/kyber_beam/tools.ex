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
      "name" => "memory_pin",
      "description" =>
        "Pin a memory so it never decays or gets garbage collected. Describe what you want to pin — searches your memory pool by tags and summary. Use for things you decide are permanently important.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Description of the memory to pin (e.g. 'pure reducer', 'night owl boundary')"
          }
        },
        "required" => ["query"]
      }
    },
    %{
      "name" => "memory_unpin",
      "description" =>
        "Unpin a memory, allowing it to decay naturally. Describe which memory to unpin.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Description of the memory to unpin"
          }
        },
        "required" => ["query"]
      }
    },
    %{
      "name" => "web_fetch",
      "description" =>
        "Fetch a URL and return clean, readable text content (like Reader View). " <>
        "Strips scripts, styles, navigation, and other non-content elements. " <>
        "Useful for reading articles, documentation, or any web page. " <>
        "Returns title, content, URL, and word count.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "url" => %{
            "type" => "string",
            "description" => "Full URL to fetch (must start with http:// or https://)"
          },
          "max_chars" => %{
            "type" => "integer",
            "description" => "Maximum characters of content to return (default: 10000)"
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
    },

    # ── Phase 7: External + Hardware ──────────────────────────────────────────

    %{
      "name" => "weather",
      "description" =>
        "Get current weather conditions and a 3-day forecast for a city or coordinates. " <>
        "Returns temperature (°C/°F), condition, humidity, wind, and feels-like.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "location" => %{
            "type" => "string",
            "description" =>
              "City name or coordinates, e.g. 'New York', 'London', '48.8566,2.3522'"
          }
        },
        "required" => ["location"]
      }
    },
    %{
      "name" => "camera_snap",
      "description" =>
        "Take a photo using the built-in FaceTime HD camera via the macOS snap daemon " <>
        "(com.liet.snap-watcher). Returns the path to the saved JPEG.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "output_path" => %{
            "type" => "string",
            "description" =>
              "Destination path for the JPEG. Defaults to /tmp/stilgar_snap_{timestamp}.jpg"
          }
        }
      }
    },

    # ── Phase 9: Discord File Posting ─────────────────────────────────────────

    %{
      "name" => "send_file",
      "description" =>
        "Send a file or image to the current Discord channel. Use this after camera_snap " <>
        "to share photos, or to send any file from allowed directories.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "file_path" => %{
            "type" => "string",
            "description" => "Path to the file to send (must be in allowed directories: ~/.kyber, ~/kyber-beam, or /tmp)"
          },
          "caption" => %{
            "type" => "string",
            "description" => "Optional caption/message to send with the file"
          },
          "channel_id" => %{
            "type" => "string",
            "description" => "Discord channel ID to send to. If omitted, uses the channel from the current conversation."
          }
        },
        "required" => ["file_path"]
      }
    },

    # ── Phase 10: Vision ──────────────────────────────────────────────────────

    %{
      "name" => "view_image",
      "description" =>
        "Load an image file and see its contents. Use this to actually look at " <>
        "photos (e.g. after camera_snap), images from disk, or any visual content. " <>
        "Returns the image data so you can describe and analyze what you see. " <>
        "IMPORTANT: Without calling this tool, you CANNOT see image contents — " <>
        "you only get file paths as text.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "path" => %{
            "type" => "string",
            "description" => "Path to the image file (JPEG, PNG, GIF, or WebP)"
          }
        },
        "required" => ["path"]
      }
    },
    # ── Phase 11: Web Search ──────────────────────────────────────────────────

    %{
      "name" => "web_search",
      "description" =>
        "Search the web for information. Returns a list of results with title, URL, " <>
        "snippet, and date. Use this to find current information, research topics, " <>
        "or verify facts. Results can be cited in your response.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "query" => %{
            "type" => "string",
            "description" => "Search query string"
          },
          "max_results" => %{
            "type" => "integer",
            "description" => "Maximum number of results to return (default 5, max 20)"
          }
        },
        "required" => ["query"]
      }
    },

    %{
      "name" => "cleanup_tmp",
      "description" =>
        "Clean up temporary files you created. Deletes files matching a prefix pattern " <>
        "in /tmp that are older than max_age_seconds. Default pattern: 'stilgar_*', " <>
        "default max age: 3600 seconds (1 hour). Use after camera_snap or any temp file work.",
      "input_schema" => %{
        "type" => "object",
        "properties" => %{
          "pattern" => %{
            "type" => "string",
            "description" => "Filename prefix pattern (e.g. 'stilgar_*'). Default: 'stilgar_*'"
          },
          "max_age_seconds" => %{
            "type" => "integer",
            "description" => "Only delete files older than this many seconds. Default: 3600"
          }
        }
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
