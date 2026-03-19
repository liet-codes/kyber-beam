defmodule Kyber.ToolExecutor do
  @moduledoc """
  Executes tool calls by name. Pure functions — no GenServer, no state.

  All handlers return `{:ok, result_string}` or `{:error, reason_string}`.
  The result string goes directly into the `tool_result` content block sent
  back to the LLM.

  Phase 4 tools: read_file, write_file, edit_file, exec, list_dir
  """

  require Logger

  @doc """
  Execute a tool by name with its input map.

  Returns `{:ok, result_string}` or `{:error, reason_string}`.
  """
  @spec execute(String.t(), map()) :: {:ok, String.t()} | {:error, String.t()}

  def execute("read_file", %{"path" => path} = input) do
    expanded = Path.expand(path)
    offset = Map.get(input, "offset", 1)
    limit = Map.get(input, "limit", 2000)

    case File.read(expanded) do
      {:ok, content} ->
        lines = String.split(content, "\n")
        total = length(lines)
        start_idx = max(0, offset - 1)

        sliced =
          lines
          |> Enum.drop(start_idx)
          |> Enum.take(limit)
          |> Enum.join("\n")

        end_line = min(offset + limit - 1, total)
        {:ok, "(#{total} lines total, showing #{offset}-#{end_line})\n#{sliced}"}

      {:error, :enoent} ->
        {:error, "File not found: #{expanded}"}

      {:error, reason} ->
        {:error, "Read error: #{inspect(reason)}"}
    end
  end

  def execute("write_file", %{"path" => path, "content" => content}) do
    expanded = Path.expand(path)

    with :ok <- File.mkdir_p(Path.dirname(expanded)),
         :ok <- File.write(expanded, content) do
      {:ok, "Written #{byte_size(content)} bytes to #{expanded}"}
    else
      {:error, reason} -> {:error, "Write error: #{inspect(reason)}"}
    end
  end

  def execute("edit_file", %{"path" => path, "old_string" => old, "new_string" => new}) do
    expanded = Path.expand(path)

    case File.read(expanded) do
      {:ok, content} ->
        if String.contains?(content, old) do
          new_content = String.replace(content, old, new, global: false)

          case File.write(expanded, new_content) do
            :ok -> {:ok, "Edit applied to #{expanded}"}
            {:error, reason} -> {:error, "Write error: #{inspect(reason)}"}
          end
        else
          {:error, "old_string not found in file — no edit applied"}
        end

      {:error, :enoent} ->
        {:error, "File not found: #{expanded}"}

      {:error, reason} ->
        {:error, "Read error: #{inspect(reason)}"}
    end
  end

  def execute("exec", %{"command" => cmd} = input) do
    workdir = Map.get(input, "workdir", System.get_env("HOME", "/tmp"))
    timeout_ms = Map.get(input, "timeout_ms", 30_000)
    expanded_dir = Path.expand(workdir)

    # Use Task.async + Task.yield for timeout support (compatible with Elixir 1.14+)
    task =
      Task.async(fn ->
        System.cmd("sh", ["-c", cmd],
          cd: expanded_dir,
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout_ms) || Task.shutdown(task) do
      {:ok, {output, 0}} ->
        {:ok, output}

      {:ok, {output, code}} ->
        {:ok, "[exit #{code}]\n#{output}"}

      nil ->
        {:error, "command timed out after #{timeout_ms}ms"}
    end
  rescue
    e -> {:error, "exec failed: #{inspect(e)}"}
  end

  def execute("list_dir", %{"path" => path}) do
    expanded = Path.expand(path)

    case File.ls(expanded) do
      {:ok, entries} ->
        formatted =
          entries
          |> Enum.sort()
          |> Enum.map(fn name ->
            full = Path.join(expanded, name)
            if File.dir?(full), do: "#{name}/", else: name
          end)
          |> Enum.join("\n")

        {:ok, formatted}

      {:error, :enoent} ->
        {:error, "Directory not found: #{expanded}"}

      {:error, reason} ->
        {:error, "List error: #{inspect(reason)}"}
    end
  end

  def execute(name, _input) do
    {:error, "Unknown tool: #{name}"}
  end
end
