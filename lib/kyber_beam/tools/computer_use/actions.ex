defmodule Kyber.Tools.ComputerUse.Actions do
  @moduledoc """
  Executes mouse/keyboard actions on the macOS desktop.

  Prefers `cliclick` when available for reliable, fast input simulation.
  Falls back to AppleScript (`osascript`) when cliclick is not installed.

  ## Supported actions

    * `:click` — left-click at (x, y)
    * `:double_click` — double-click at (x, y)
    * `:right_click` — right-click at (x, y)
    * `:move` — move mouse to (x, y)
    * `:type` — type text string
    * `:key` — press a key or key combo (e.g. "return", "cmd+c")
    * `:scroll` — scroll up or down

  ## Security

  Coordinates are bounds-checked against the screen dimensions to prevent
  clicking outside the visible area.
  """

  require Logger

  # Reasonable screen bounds — max 8K display
  @max_x 7680
  @max_y 4320

  @type action ::
          {:click, integer(), integer()}
          | {:double_click, integer(), integer()}
          | {:right_click, integer(), integer()}
          | {:move, integer(), integer()}
          | {:type, String.t()}
          | {:key, String.t()}
          | {:scroll, :up | :down, integer()}

  @doc """
  Execute an action on the macOS desktop.

  ## Options

    * `:cmd_runner` — function for running shell commands (for testing)
    * `:cliclick_available` — override cliclick detection (for testing)

  Returns `{:ok, description}` or `{:error, reason}`.
  """
  @spec execute(action(), keyword()) :: {:ok, String.t()} | {:error, String.t()}
  def execute(action, opts \\ [])

  def execute({:click, x, y}, opts) do
    with :ok <- validate_coords(x, y) do
      run_input(:click, x, y, opts)
    end
  end

  def execute({:double_click, x, y}, opts) do
    with :ok <- validate_coords(x, y) do
      run_input(:double_click, x, y, opts)
    end
  end

  def execute({:right_click, x, y}, opts) do
    with :ok <- validate_coords(x, y) do
      run_input(:right_click, x, y, opts)
    end
  end

  def execute({:move, x, y}, opts) do
    with :ok <- validate_coords(x, y) do
      run_input(:move, x, y, opts)
    end
  end

  def execute({:type, text}, opts) when is_binary(text) do
    run_type(text, opts)
  end

  def execute({:key, key_spec}, opts) when is_binary(key_spec) do
    run_key(key_spec, opts)
  end

  def execute({:scroll, direction, amount}, opts)
      when direction in [:up, :down] and is_integer(amount) and amount > 0 do
    run_scroll(direction, amount, opts)
  end

  def execute(action, _opts) do
    {:error, "Invalid action: #{inspect(action)}"}
  end

  # ── Coordinate validation ──────────────────────────────────────────────

  defp validate_coords(x, y) when is_integer(x) and is_integer(y) do
    cond do
      x < 0 or y < 0 ->
        {:error, "Coordinates must be non-negative: (#{x}, #{y})"}

      x > @max_x or y > @max_y ->
        {:error, "Coordinates out of bounds: (#{x}, #{y}), max (#{@max_x}, #{@max_y})"}

      true ->
        :ok
    end
  end

  defp validate_coords(x, y) do
    {:error, "Coordinates must be integers: (#{inspect(x)}, #{inspect(y)})"}
  end

  # ── Input execution (cliclick vs AppleScript) ──────────────────────────

  defp has_cliclick?(opts) do
    case Keyword.get(opts, :cliclick_available) do
      nil ->
        cmd_runner = Keyword.get(opts, :cmd_runner, &System.cmd/3)

        case cmd_runner.("which", ["cliclick"], stderr_to_stdout: true) do
          {_, 0} -> true
          _ -> false
        end

      val ->
        val
    end
  end

  defp cmd_runner(opts), do: Keyword.get(opts, :cmd_runner, &System.cmd/3)

  defp run_input(action, x, y, opts) do
    if has_cliclick?(opts) do
      cliclick_input(action, x, y, opts)
    else
      applescript_input(action, x, y, opts)
    end
  end

  # ── cliclick commands ──────────────────────────────────────────────────

  defp cliclick_input(:click, x, y, opts) do
    run_cliclick(["c:#{x},#{y}"], "Clicked at (#{x}, #{y})", opts)
  end

  defp cliclick_input(:double_click, x, y, opts) do
    run_cliclick(["dc:#{x},#{y}"], "Double-clicked at (#{x}, #{y})", opts)
  end

  defp cliclick_input(:right_click, x, y, opts) do
    run_cliclick(["rc:#{x},#{y}"], "Right-clicked at (#{x}, #{y})", opts)
  end

  defp cliclick_input(:move, x, y, opts) do
    run_cliclick(["m:#{x},#{y}"], "Moved mouse to (#{x}, #{y})", opts)
  end

  defp run_cliclick(args, success_msg, opts) do
    case cmd_runner(opts).("cliclick", args, stderr_to_stdout: true) do
      {_, 0} -> {:ok, success_msg}
      {output, code} -> {:error, "cliclick failed (exit #{code}): #{output}"}
    end
  end

  defp run_type(text, opts) do
    if has_cliclick?(opts) do
      # cliclick t: types text
      case cmd_runner(opts).("cliclick", ["t:#{text}"], stderr_to_stdout: true) do
        {_, 0} -> {:ok, "Typed: #{String.slice(text, 0, 50)}#{if String.length(text) > 50, do: "...", else: ""}"}
        {output, code} -> {:error, "cliclick type failed (exit #{code}): #{output}"}
      end
    else
      # AppleScript keystroke
      escaped = String.replace(text, "\"", "\\\"")
      script = ~s(tell application "System Events" to keystroke "#{escaped}")

      case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
        {_, 0} -> {:ok, "Typed: #{String.slice(text, 0, 50)}#{if String.length(text) > 50, do: "...", else: ""}"}
        {output, code} -> {:error, "osascript type failed (exit #{code}): #{output}"}
      end
    end
  end

  defp run_key(key_spec, opts) do
    if has_cliclick?(opts) do
      cliclick_key(key_spec, opts)
    else
      applescript_key(key_spec, opts)
    end
  end

  defp cliclick_key(key_spec, opts) do
    # Handle modifier combos like "cmd+c" → need to split
    if String.contains?(key_spec, "+") do
      parts = String.split(key_spec, "+")
      key = List.last(parts)
      modifiers = Enum.slice(parts, 0..-2//1)

      # cliclick uses kd/ku for modifier hold + kp for key
      mod_args =
        Enum.flat_map(modifiers, fn mod ->
          case normalize_modifier(mod) do
            {:ok, m} -> ["kd:#{m}"]
            :error -> []
          end
        end)

      release_args =
        modifiers
        |> Enum.reverse()
        |> Enum.flat_map(fn mod ->
          case normalize_modifier(mod) do
            {:ok, m} -> ["ku:#{m}"]
            :error -> []
          end
        end)

      all_args = mod_args ++ ["kp:#{key}"] ++ release_args

      case cmd_runner(opts).("cliclick", all_args, stderr_to_stdout: true) do
        {_, 0} -> {:ok, "Key press: #{key_spec}"}
        {output, code} -> {:error, "cliclick key failed (exit #{code}): #{output}"}
      end
    else
      case cmd_runner(opts).("cliclick", ["kp:#{key_spec}"], stderr_to_stdout: true) do
        {_, 0} -> {:ok, "Key press: #{key_spec}"}
        {output, code} -> {:error, "cliclick key failed (exit #{code}): #{output}"}
      end
    end
  end

  defp normalize_modifier(mod) do
    case String.downcase(mod) do
      "cmd" -> {:ok, "cmd"}
      "command" -> {:ok, "cmd"}
      "ctrl" -> {:ok, "ctrl"}
      "control" -> {:ok, "ctrl"}
      "alt" -> {:ok, "alt"}
      "option" -> {:ok, "alt"}
      "shift" -> {:ok, "shift"}
      _ -> :error
    end
  end

  defp applescript_key(key_spec, opts) do
    if String.contains?(key_spec, "+") do
      parts = String.split(key_spec, "+")
      key = List.last(parts)
      modifiers = Enum.slice(parts, 0..-2//1)

      using_clause =
        modifiers
        |> Enum.map(fn mod ->
          case String.downcase(mod) do
            m when m in ["cmd", "command"] -> "command down"
            m when m in ["ctrl", "control"] -> "control down"
            m when m in ["alt", "option"] -> "option down"
            "shift" -> "shift down"
            other -> "#{other} down"
          end
        end)
        |> Enum.join(", ")

      script =
        case key_to_keycode(key) do
          {:keycode, code} ->
            ~s(tell application "System Events" to key code #{code} using {#{using_clause}})

          {:keystroke, char} ->
            ~s(tell application "System Events" to keystroke "#{char}" using {#{using_clause}})
        end

      case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
        {_, 0} -> {:ok, "Key press: #{key_spec}"}
        {output, code} -> {:error, "osascript key failed (exit #{code}): #{output}"}
      end
    else
      script =
        case key_to_keycode(key_spec) do
          {:keycode, code} ->
            ~s(tell application "System Events" to key code #{code})

          {:keystroke, char} ->
            ~s(tell application "System Events" to keystroke "#{char}")
        end

      case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
        {_, 0} -> {:ok, "Key press: #{key_spec}"}
        {output, code} -> {:error, "osascript key failed (exit #{code}): #{output}"}
      end
    end
  end

  defp key_to_keycode(key) do
    case String.downcase(key) do
      "return" -> {:keycode, 36}
      "enter" -> {:keycode, 36}
      "tab" -> {:keycode, 48}
      "escape" -> {:keycode, 53}
      "esc" -> {:keycode, 53}
      "space" -> {:keycode, 49}
      "delete" -> {:keycode, 51}
      "backspace" -> {:keycode, 51}
      "up" -> {:keycode, 126}
      "down" -> {:keycode, 125}
      "left" -> {:keycode, 123}
      "right" -> {:keycode, 124}
      "f1" -> {:keycode, 122}
      "f2" -> {:keycode, 120}
      "f3" -> {:keycode, 99}
      "f4" -> {:keycode, 118}
      "f5" -> {:keycode, 96}
      char -> {:keystroke, char}
    end
  end

  defp run_scroll(direction, amount, opts) do
    # AppleScript scroll — cliclick doesn't have great scroll support
    dir_value = if direction == :up, do: amount, else: -amount

    script = """
    tell application "System Events"
      repeat #{abs(dir_value)} times
        #{if direction == :up, do: "key code 126 using {option down}", else: "key code 125 using {option down}"}
      end repeat
    end tell
    """

    case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} -> {:ok, "Scrolled #{direction} #{amount} steps"}
      {output, code} -> {:error, "osascript scroll failed (exit #{code}): #{output}"}
    end
  end

  # ── AppleScript fallback for mouse actions ─────────────────────────────

  defp applescript_input(:click, x, y, opts) do
    script = ~s(tell application "System Events" to click at {#{x}, #{y}})

    case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} -> {:ok, "Clicked at (#{x}, #{y}) [AppleScript]"}
      {output, code} -> {:error, "osascript click failed (exit #{code}): #{output}"}
    end
  end

  defp applescript_input(:double_click, x, y, opts) do
    script = ~s(tell application "System Events" to double click at {#{x}, #{y}})

    case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} -> {:ok, "Double-clicked at (#{x}, #{y}) [AppleScript]"}
      {output, code} -> {:error, "osascript double-click failed (exit #{code}): #{output}"}
    end
  end

  defp applescript_input(:right_click, x, y, opts) do
    # AppleScript doesn't have native right-click at coordinates easily;
    # use control-click as a workaround
    script = """
    tell application "System Events"
      click at {#{x}, #{y}} with control key down
    end tell
    """

    case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} -> {:ok, "Right-clicked at (#{x}, #{y}) [AppleScript]"}
      {output, code} -> {:error, "osascript right-click failed (exit #{code}): #{output}"}
    end
  end

  defp applescript_input(:move, x, y, opts) do
    # AppleScript can't easily move the mouse without clicking.
    # We'll use python as a fallback if available, otherwise error.
    script = """
    do shell script "python3 -c \\"
    import Quartz
    Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, (#{x}, #{y}), 0))
    \\""
    """

    case cmd_runner(opts).("osascript", ["-e", script], stderr_to_stdout: true) do
      {_, 0} -> {:ok, "Moved mouse to (#{x}, #{y}) [AppleScript+Python]"}
      {output, code} -> {:error, "mouse move failed (exit #{code}): #{output}. Install cliclick: brew install cliclick"}
    end
  end

  @doc """
  Check if cliclick is available on the system.
  """
  @spec cliclick_available?(keyword()) :: boolean()
  def cliclick_available?(opts \\ []) do
    cmd_runner = Keyword.get(opts, :cmd_runner, &System.cmd/3)

    case cmd_runner.("which", ["cliclick"], stderr_to_stdout: true) do
      {_, 0} -> true
      _ -> false
    end
  end
end
