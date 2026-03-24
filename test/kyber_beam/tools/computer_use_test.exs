defmodule Kyber.Tools.ComputerUseTest do
  use ExUnit.Case, async: true

  alias Kyber.Tools.ComputerUse.Screenshot
  alias Kyber.Tools.ComputerUse.Actions

  # ── Mock helpers ──────────────────────────────────────────────────────────

  # Build a cmd_runner that returns predefined responses based on the executable
  defp mock_runner(responses) do
    fn executable, args, _opts ->
      key = {executable, args}

      # Try exact match first, then match by executable only
      case Map.get(responses, key) || Map.get(responses, executable) do
        nil -> {"", 0}
        {output, code} -> {output, code}
        fun when is_function(fun, 2) -> fun.(executable, args)
      end
    end
  end

  # ── Screenshot Tests ──────────────────────────────────────────────────────

  describe "Screenshot.capture/1" do
    test "captures full screen screenshot" do
      # Create a real tiny PNG for the test
      tmp_path = "/tmp/kyber_screenshot_test_#{System.unique_integer([:positive])}.png"

      runner = fn executable, args, _opts ->
        case executable do
          "screencapture" ->
            # Write a minimal file so File.read works
            File.write!(List.last(args), "fake-png-data")
            {"", 0}

          "sips" ->
            if "-g" in args do
              {"pixelWidth: 1024\npixelHeight: 768\n", 0}
            else
              {"", 0}
            end
        end
      end

      result = Screenshot.capture(cmd_runner: runner, tmp_path: tmp_path)

      assert {:ok, %{base64: base64, width: 1024, height: 768, format: "png"}} = result
      assert is_binary(base64)
      assert Base.decode64!(base64) == "fake-png-data"
    after
      File.rm("/tmp/kyber_screenshot_test_*")
    end

    test "resizes image when wider than 1280px" do
      tmp_path = "/tmp/kyber_screenshot_resize_test_#{System.unique_integer([:positive])}.png"
      table_name = :"resize_test_#{System.unique_integer([:positive])}"
      resize_called = :ets.new(table_name, [:set, :public])

      runner = fn executable, args, _opts ->
        case executable do
          "screencapture" ->
            File.write!(List.last(args), "fake-png")
            {"", 0}

          "sips" ->
            cond do
              "--resampleWidth" in args ->
                :ets.insert(resize_called, {:called, true})
                {"", 0}

              "-g" in args ->
                # First call returns wide, subsequent calls return resized
                case :ets.lookup(resize_called, :called) do
                  [{:called, true}] ->
                    {"pixelWidth: 1280\npixelHeight: 900\n", 0}

                  _ ->
                    {"pixelWidth: 2560\npixelHeight: 1800\n", 0}
                end
            end
        end
      end

      result = Screenshot.capture(cmd_runner: runner, tmp_path: tmp_path)

      assert {:ok, %{width: 1280, height: 900}} = result
      assert [{:called, true}] = :ets.lookup(resize_called, :called)
    after
      :ok
    end

    test "returns error when screencapture fails" do
      runner = fn "screencapture", _args, _opts ->
        {"screencapture: no screen available", 1}
      end

      result = Screenshot.capture(cmd_runner: runner)
      assert {:error, "screencapture failed" <> _} = result
    end
  end

  # ── Actions Tests ─────────────────────────────────────────────────────────

  describe "Actions.execute/2 with cliclick" do
    setup do
      runner = fn executable, args, _opts -> {inspect({executable, args}), 0} end
      [opts: [cmd_runner: runner, cliclick_available: true]]
    end

    test "click at coordinates", %{opts: opts} do
      assert {:ok, "Clicked at (100, 200)"} = Actions.execute({:click, 100, 200}, opts)
    end

    test "double-click at coordinates", %{opts: opts} do
      assert {:ok, "Double-clicked at (300, 400)"} =
               Actions.execute({:double_click, 300, 400}, opts)
    end

    test "right-click at coordinates", %{opts: opts} do
      assert {:ok, "Right-clicked at (500, 600)"} =
               Actions.execute({:right_click, 500, 600}, opts)
    end

    test "move mouse", %{opts: opts} do
      assert {:ok, "Moved mouse to (150, 250)"} = Actions.execute({:move, 150, 250}, opts)
    end

    test "type text", %{opts: opts} do
      assert {:ok, "Typed: hello world"} = Actions.execute({:type, "hello world"}, opts)
    end

    test "simple key press", %{opts: opts} do
      assert {:ok, "Key press: return"} = Actions.execute({:key, "return"}, opts)
    end

    test "key combo (cmd+c)", %{opts: opts} do
      assert {:ok, "Key press: cmd+c"} = Actions.execute({:key, "cmd+c"}, opts)
    end
  end

  describe "Actions.execute/2 with AppleScript fallback" do
    setup do
      runner = fn executable, args, _opts -> {inspect({executable, args}), 0} end
      [opts: [cmd_runner: runner, cliclick_available: false]]
    end

    test "click via AppleScript", %{opts: opts} do
      assert {:ok, "Clicked at (100, 200) [AppleScript]"} =
               Actions.execute({:click, 100, 200}, opts)
    end

    test "type via AppleScript", %{opts: opts} do
      assert {:ok, "Typed: test"} = Actions.execute({:type, "test"}, opts)
    end

    test "key press via AppleScript", %{opts: opts} do
      assert {:ok, "Key press: return"} = Actions.execute({:key, "return"}, opts)
    end

    test "key combo via AppleScript", %{opts: opts} do
      assert {:ok, "Key press: cmd+v"} = Actions.execute({:key, "cmd+v"}, opts)
    end
  end

  describe "Actions coordinate validation" do
    setup do
      runner = fn _, _, _ -> {"", 0} end
      [opts: [cmd_runner: runner, cliclick_available: true]]
    end

    test "rejects negative coordinates", %{opts: opts} do
      assert {:error, "Coordinates must be non-negative" <> _} =
               Actions.execute({:click, -1, 100}, opts)
    end

    test "rejects out-of-bounds coordinates", %{opts: opts} do
      assert {:error, "Coordinates out of bounds" <> _} =
               Actions.execute({:click, 10000, 100}, opts)
    end

    test "rejects non-integer coordinates", %{opts: opts} do
      assert {:error, "Coordinates must be integers" <> _} =
               Actions.execute({:click, 1.5, 2.5}, opts)
    end
  end

  describe "Actions.execute/2 scroll" do
    test "scrolls down" do
      runner = fn _, _, _ -> {"", 0} end
      opts = [cmd_runner: runner, cliclick_available: true]

      assert {:ok, "Scrolled down 3 steps"} = Actions.execute({:scroll, :down, 3}, opts)
    end

    test "scrolls up" do
      runner = fn _, _, _ -> {"", 0} end
      opts = [cmd_runner: runner, cliclick_available: true]

      assert {:ok, "Scrolled up 5 steps"} = Actions.execute({:scroll, :up, 5}, opts)
    end

    test "rejects invalid scroll direction" do
      assert {:error, "Invalid action" <> _} =
               Actions.execute({:scroll, :left, 3}, [])
    end
  end

  describe "Actions.cliclick_available?/1" do
    test "returns true when cliclick is found" do
      runner = fn "which", ["cliclick"], _opts -> {"/usr/local/bin/cliclick\n", 0} end
      assert Actions.cliclick_available?(cmd_runner: runner) == true
    end

    test "returns false when cliclick is not found" do
      runner = fn "which", ["cliclick"], _opts -> {"", 1} end
      assert Actions.cliclick_available?(cmd_runner: runner) == false
    end
  end

  # ── Tool Executor Integration Tests ───────────────────────────────────────

  describe "ToolExecutor.execute(\"computer_use\", ...)" do
    test "rejects unknown action" do
      assert {:error, "Unknown computer_use action: fly"} =
               Kyber.ToolExecutor.execute("computer_use", %{"action" => "fly"})
    end

    test "requires coordinates for click" do
      assert {:error, "click requires x and y coordinates"} =
               Kyber.ToolExecutor.execute("computer_use", %{"action" => "click"})
    end

    test "requires text for type" do
      assert {:error, "type action requires 'text' parameter"} =
               Kyber.ToolExecutor.execute("computer_use", %{"action" => "type"})
    end

    test "requires key for key action" do
      assert {:error, "key action requires 'key' parameter"} =
               Kyber.ToolExecutor.execute("computer_use", %{"action" => "key"})
    end
  end
end
