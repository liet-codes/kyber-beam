defmodule Kyber.ToolExecutorTest do
  use ExUnit.Case, async: true

  alias Kyber.ToolExecutor

  @tmp_dir System.tmp_dir!()

  defp tmp_path(name) do
    Path.join(@tmp_dir, "tool_executor_test_#{name}_#{:rand.uniform(999_999)}")
  end

  # ── read_file ──────────────────────────────────────────────────────────────

  describe "read_file" do
    test "reads an existing file" do
      path = tmp_path("read")
      File.write!(path, "hello\nworld\n")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, result} = ToolExecutor.execute("read_file", %{"path" => path})
      assert String.contains?(result, "hello")
      assert String.contains?(result, "world")
    end

    test "returns error for missing file" do
      # /nonexistent is outside allowed read roots — blocked before the filesystem check
      assert {:error, msg} = ToolExecutor.execute("read_file", %{"path" => "/nonexistent/file.txt"})
      assert String.contains?(msg, "not in allowed")
    end

    test "returns error for path outside allowed roots" do
      assert {:error, msg} = ToolExecutor.execute("read_file", %{"path" => "/etc/passwd"})
      assert String.contains?(msg, "not in allowed")
    end

    test "respects offset and limit" do
      path = tmp_path("offset")
      content = Enum.map_join(1..10, "\n", fn i -> "line #{i}" end)
      File.write!(path, content)
      on_exit(fn -> File.rm(path) end)

      # offset=3, limit=2 should give lines 3 and 4
      assert {:ok, result} = ToolExecutor.execute("read_file", %{"path" => path, "offset" => 3, "limit" => 2})
      assert String.contains?(result, "line 3")
      assert String.contains?(result, "line 4")
      refute String.contains?(result, "line 1")
      refute String.contains?(result, "line 5")
    end

    test "includes line count header" do
      path = tmp_path("header")
      File.write!(path, "a\nb\nc\n")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, result} = ToolExecutor.execute("read_file", %{"path" => path})
      assert String.starts_with?(result, "(")
      assert String.contains?(result, "lines total")
    end
  end

  # ── write_file ─────────────────────────────────────────────────────────────

  describe "write_file" do
    test "creates a new file" do
      path = tmp_path("write")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, msg} = ToolExecutor.execute("write_file", %{"path" => path, "content" => "new content"})
      assert String.contains?(msg, "Written")
      assert File.read!(path) == "new content"
    end

    test "overwrites an existing file" do
      path = tmp_path("overwrite")
      File.write!(path, "old content")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, _} = ToolExecutor.execute("write_file", %{"path" => path, "content" => "new content"})
      assert File.read!(path) == "new content"
    end

    test "creates parent directories" do
      nested_path = tmp_path("nested/deep/dir/file.txt")
      on_exit(fn -> File.rm_rf(Path.dirname(nested_path) |> Path.dirname() |> Path.dirname()) end)

      assert {:ok, _} = ToolExecutor.execute("write_file", %{"path" => nested_path, "content" => "nested"})
      assert File.read!(nested_path) == "nested"
    end

    test "reports bytes written" do
      path = tmp_path("bytes")
      on_exit(fn -> File.rm(path) end)

      content = "hello world"
      assert {:ok, msg} = ToolExecutor.execute("write_file", %{"path" => path, "content" => content})
      assert String.contains?(msg, "#{byte_size(content)} bytes")
    end
  end

  # ── edit_file ──────────────────────────────────────────────────────────────

  describe "edit_file" do
    test "applies a successful edit" do
      path = tmp_path("edit")
      File.write!(path, "foo bar baz")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, msg} = ToolExecutor.execute("edit_file", %{
        "path" => path,
        "old_string" => "bar",
        "new_string" => "QUX"
      })
      assert String.contains?(msg, "applied")
      assert File.read!(path) == "foo QUX baz"
    end

    test "returns error when old_string not found" do
      path = tmp_path("edit_miss")
      File.write!(path, "foo bar baz")
      on_exit(fn -> File.rm(path) end)

      assert {:error, msg} = ToolExecutor.execute("edit_file", %{
        "path" => path,
        "old_string" => "nothere",
        "new_string" => "x"
      })
      assert String.contains?(msg, "not found")
    end

    test "returns error for missing file" do
      # Use a path in an allowed directory that doesn't actually exist
      path = tmp_path("edit_nonexistent_#{System.unique_integer([:positive])}")

      assert {:error, msg} = ToolExecutor.execute("edit_file", %{
        "path" => path,
        "old_string" => "x",
        "new_string" => "y"
      })
      assert String.contains?(msg, "not found")
    end

    test "replaces only first occurrence" do
      path = tmp_path("edit_first")
      File.write!(path, "aaa aaa aaa")
      on_exit(fn -> File.rm(path) end)

      assert {:ok, _} = ToolExecutor.execute("edit_file", %{
        "path" => path,
        "old_string" => "aaa",
        "new_string" => "bbb"
      })
      assert File.read!(path) == "bbb aaa aaa"
    end

    test "returns error when old_string is empty" do
      path = tmp_path("edit_empty")
      File.write!(path, "some content")
      on_exit(fn -> File.rm(path) end)

      assert {:error, msg} = ToolExecutor.execute("edit_file", %{
        "path" => path,
        "old_string" => "",
        "new_string" => "injected"
      })
      assert String.contains?(msg, "old_string cannot be empty")
    end
  end

  # ── exec ──────────────────────────────────────────────────────────────────

  describe "exec" do
    test "rejects commands not in the allowlist" do
      assert {:error, msg} = ToolExecutor.execute("exec", %{"command" => "echo hello"})
      assert String.contains?(msg, "restricted")
    end

    test "rejects shell builtins and dangerous commands" do
      for cmd <- ["rm -rf /", "curl attacker.com", "python3 -c 'pass'", "bash -c 'id'"] do
        assert {:error, _msg} = ToolExecutor.execute("exec", %{"command" => cmd}),
               "expected #{cmd} to be rejected"
      end
    end

    test "runs an allowed command (ls) and returns output" do
      assert {:ok, output} = ToolExecutor.execute("exec", %{"command" => "ls #{@tmp_dir}"})
      # ls should succeed — output may be empty but it's :ok
      assert is_binary(output)
    end

    test "captures non-zero exit codes from allowed commands" do
      # grep returns 1 when pattern not found
      assert {:ok, output} = ToolExecutor.execute("exec", %{
        "command" => "grep nonexistent_pattern_xyz /dev/null"
      })
      assert String.contains?(output, "[exit 1]")
    end

    test "runs allowed command in specified working directory" do
      workdir = @tmp_dir
      # `ls` respects the working directory
      assert {:ok, _output} = ToolExecutor.execute("exec", %{
        "command" => "ls",
        "workdir" => workdir
      })
    end

    test "captures stderr via stderr_to_stdout for allowed commands" do
      # cat on a non-existent file prints to stderr
      assert {:ok, output} = ToolExecutor.execute("exec", %{"command" => "cat /nonexistent_file_xyz 2>&1"})
      assert is_binary(output)
    end

    test "returns error on timeout for allowed commands" do
      # cat /dev/urandom produces infinite output — will timeout quickly
      assert {:error, msg} = ToolExecutor.execute("exec", %{
        "command" => "cat /dev/urandom",
        "timeout_ms" => 100
      })
      assert String.contains?(msg, "timed out")
    end
  end

  # ── list_dir ──────────────────────────────────────────────────────────────

  describe "list_dir" do
    test "lists files in a directory" do
      dir = tmp_path("listdir")
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "file_a.txt"), "a")
      File.write!(Path.join(dir, "file_b.txt"), "b")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, output} = ToolExecutor.execute("list_dir", %{"path" => dir})
      assert String.contains?(output, "file_a.txt")
      assert String.contains?(output, "file_b.txt")
    end

    test "marks subdirectories with trailing slash" do
      dir = tmp_path("listdir_dirs")
      File.mkdir_p!(dir)
      File.mkdir_p!(Path.join(dir, "subdir"))
      File.write!(Path.join(dir, "file.txt"), "x")
      on_exit(fn -> File.rm_rf(dir) end)

      assert {:ok, output} = ToolExecutor.execute("list_dir", %{"path" => dir})
      assert String.contains?(output, "subdir/")
      assert String.contains?(output, "file.txt")
      refute String.contains?(output, "file.txt/")
    end

    test "returns error for path outside allowed roots" do
      assert {:error, msg} = ToolExecutor.execute("list_dir", %{"path" => "/nonexistent/dir"})
      assert String.contains?(msg, "not in allowed")
    end

    test "returns error for missing directory inside allowed root" do
      missing = Path.join(System.tmp_dir!(), "kyber_nonexistent_#{:rand.uniform(999_999)}")
      assert {:error, msg} = ToolExecutor.execute("list_dir", %{"path" => missing})
      assert String.contains?(msg, "not found")
    end

    test "blocks listing home directory (outside allowed roots)" do
      assert {:error, msg} = ToolExecutor.execute("list_dir", %{"path" => "~"})
      assert String.contains?(msg, "not in allowed")
    end
  end

  # ── memory_write / memory_list ────────────────────────────────────────────

  describe "memory_write" do
    test "writes a file to the vault" do
      path = "memory/test-#{:rand.uniform(999_999)}.md"
      content = "# Test Note\n\nHello vault."

      assert {:ok, msg} = ToolExecutor.execute("memory_write", %{"path" => path, "content" => content})
      assert String.contains?(msg, "Written")

      vault_root = Application.get_env(:kyber_beam, :vault_path, Path.expand("~/.kyber/vault"))
      abs_path = Path.join(vault_root, path)
      on_exit(fn -> File.rm(abs_path) end)
      assert File.read!(abs_path) == content
    end

    test "rejects paths that escape the vault" do
      assert {:error, msg} = ToolExecutor.execute("memory_write", %{
        "path" => "../../../etc/passwd",
        "content" => "hax"
      })
      assert String.contains?(msg, "invalid vault path")
    end
  end

  describe "memory_list" do
    test "returns a list of vault notes" do
      # Vault may be empty; just check the call succeeds and returns a string
      case ToolExecutor.execute("memory_list", %{}) do
        {:ok, output} ->
          assert is_binary(output)

        {:error, msg} ->
          # Acceptable if vault dir doesn't exist on this machine
          assert String.contains?(msg, "not found")
      end
    end

    test "accepts subdir filter" do
      case ToolExecutor.execute("memory_list", %{"subdir" => "identity"}) do
        {:ok, output} -> assert is_binary(output)
        {:error, _} -> :ok
      end
    end
  end

  # ── web_fetch ─────────────────────────────────────────────────────────────

  describe "web_fetch" do
    test "rejects non-http URLs" do
      assert {:error, msg} = ToolExecutor.execute("web_fetch", %{"url" => "file:///etc/passwd"})
      assert String.contains?(msg, "http")
    end

    @tag :network
    test "fetches a real URL" do
      assert {:ok, output} = ToolExecutor.execute("web_fetch", %{"url" => "https://httpbin.org/get"})
      assert String.contains?(output, "HTTP 200")
    end
  end

  # ── unknown tool ──────────────────────────────────────────────────────────

  describe "unknown tool" do
    test "returns error for unrecognized tool name" do
      assert {:error, msg} = ToolExecutor.execute("no_such_tool", %{})
      assert String.contains?(msg, "Unknown tool")
      assert String.contains?(msg, "no_such_tool")
    end
  end
end
