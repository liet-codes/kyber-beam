defmodule Kyber.Tools.BrowserTest do
  use ExUnit.Case, async: true

  alias Kyber.Tools.Browser

  describe "execute/2 action validation" do
    test "unknown action returns error" do
      assert {:error, msg} = Browser.execute("invalid_action", %{})
      assert msg =~ "Unknown browser action"
    end

    test "navigate without url returns error" do
      assert {:error, msg} = Browser.execute("navigate", %{})
      assert msg =~ "requires 'url'"
    end

    test "click without selector returns error" do
      assert {:error, msg} = Browser.execute("click", %{})
      assert msg =~ "requires 'selector'"
    end

    test "type without selector returns error" do
      assert {:error, msg} = Browser.execute("type", %{"text" => "hello"})
      assert msg =~ "requires 'selector' and 'text'"
    end

    test "type without text returns error" do
      assert {:error, msg} = Browser.execute("type", %{"selector" => "#input"})
      assert msg =~ "requires 'selector' and 'text'"
    end

    test "evaluate without javascript returns error" do
      assert {:error, msg} = Browser.execute("evaluate", %{})
      assert msg =~ "requires 'javascript'"
    end

    test "read without selector returns error" do
      assert {:error, msg} = Browser.execute("read", %{})
      assert msg =~ "requires 'selector'"
    end
  end

  describe "execute/2 without Chrome running" do
    # These tests verify graceful failure when Chrome isn't available
    # They don't actually launch Chrome

    test "navigate fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("navigate", %{"url" => "https://example.com"})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end

    test "screenshot fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("screenshot", %{})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end

    test "get_text fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("get_text", %{})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end

    test "evaluate fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("evaluate", %{"javascript" => "1+1"})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end

    test "click fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("click", %{"selector" => "#btn"})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end

    test "type fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("type", %{"selector" => "#input", "text" => "hi"})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end

    test "read fails gracefully without Chrome" do
      assert {:error, msg} = Browser.execute("read", %{"selector" => "body"})
      assert msg =~ "Chrome" or msg =~ "connect" or msg =~ "failed"
    end
  end

  describe "Chrome module" do
    alias Kyber.Tools.Browser.Chrome

    test "debug_port_available? returns false when Chrome isn't running on 9222" do
      # This will be false unless Chrome is actually running with debug port
      # Either way, it shouldn't crash
      result = Chrome.debug_port_available?()
      assert is_boolean(result)
    end

    test "get_debug_ws_url returns error when Chrome isn't running" do
      # May succeed if Chrome is actually running, but shouldn't crash
      case Chrome.get_debug_ws_url() do
        {:ok, url} -> assert String.starts_with?(url, "ws://")
        {:error, reason} -> assert is_binary(reason)
      end
    end
  end

  describe "tool definition" do
    test "browser tool is in Kyber.Tools.definitions" do
      tools = Kyber.Tools.definitions()
      browser_tool = Enum.find(tools, fn t -> t["name"] == "browser" end)

      assert browser_tool != nil
      assert browser_tool["input_schema"]["properties"]["action"] != nil

      actions = browser_tool["input_schema"]["properties"]["action"]["enum"]
      assert "launch" in actions
      assert "navigate" in actions
      assert "click" in actions
      assert "type" in actions
      assert "read" in actions
      assert "screenshot" in actions
      assert "evaluate" in actions
      assert "get_text" in actions
    end

    test "browser tool has required action parameter" do
      tools = Kyber.Tools.definitions()
      browser_tool = Enum.find(tools, fn t -> t["name"] == "browser" end)

      assert "action" in browser_tool["input_schema"]["required"]
    end
  end

  describe "tool executor routing" do
    test "browser action is routed through ToolExecutor" do
      # Should fail gracefully (no Chrome), but proves routing works
      assert {:error, _} = Kyber.ToolExecutor.execute("browser", %{"action" => "screenshot"})
    end

    test "unknown browser action through executor" do
      assert {:error, msg} = Kyber.ToolExecutor.execute("browser", %{"action" => "fly"})
      assert msg =~ "Unknown browser action"
    end
  end
end
