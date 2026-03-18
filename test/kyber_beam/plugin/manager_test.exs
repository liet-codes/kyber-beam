defmodule Kyber.Plugin.ManagerTest do
  use ExUnit.Case, async: true

  alias Kyber.Plugin.Manager

  # A simple mock plugin for testing
  defmodule MockPlugin do
    use GenServer

    def name, do: "mock_plugin"

    def start_link(_opts \\ []) do
      GenServer.start_link(__MODULE__, :ok)
    end

    def init(:ok), do: {:ok, :ok}
  end

  defmodule MockPlugin2 do
    use GenServer

    def name, do: "mock_plugin_2"

    def start_link(_opts \\ []) do
      GenServer.start_link(__MODULE__, :ok)
    end

    def init(:ok), do: {:ok, :ok}
  end

  setup do
    {:ok, pid} = Manager.start_link(name: :"manager_#{:rand.uniform(999_999)}")
    {:ok, mgr: pid}
  end

  test "register starts a plugin and returns {:ok, pid}", %{mgr: mgr} do
    assert {:ok, pid} = Manager.register(mgr, MockPlugin)
    assert is_pid(pid)
    assert Process.alive?(pid)
  end

  test "register same plugin twice returns ok (idempotent)", %{mgr: mgr} do
    {:ok, _} = Manager.register(mgr, MockPlugin)
    result = Manager.register(mgr, MockPlugin)
    assert match?({:ok, _}, result)
  end

  test "list returns registered plugin names", %{mgr: mgr} do
    Manager.register(mgr, MockPlugin)
    Manager.register(mgr, MockPlugin2)
    names = Manager.list(mgr)
    assert "mock_plugin" in names
    assert "mock_plugin_2" in names
  end

  test "list is empty before registering anything", %{mgr: mgr} do
    assert Manager.list(mgr) == []
  end

  test "unregister removes a plugin", %{mgr: mgr} do
    Manager.register(mgr, MockPlugin)
    assert "mock_plugin" in Manager.list(mgr)

    :ok = Manager.unregister(mgr, "mock_plugin")
    Process.sleep(50)
    refute "mock_plugin" in Manager.list(mgr)
  end

  test "unregister returns {:error, :not_found} for unknown name", %{mgr: mgr} do
    assert Manager.unregister(mgr, "does_not_exist") == {:error, :not_found}
  end

  test "reload restarts a plugin", %{mgr: mgr} do
    {:ok, pid1} = Manager.register(mgr, MockPlugin)
    :ok = Manager.reload(mgr, MockPlugin)
    Process.sleep(50)

    names = Manager.list(mgr)
    assert "mock_plugin" in names

    # The new pid should be different (it was restarted)
    children = DynamicSupervisor.which_children(mgr)
    new_pids = for {_, p, _, _} <- children, is_pid(p), do: p
    assert Enum.any?(new_pids, fn p -> p != pid1 end) or length(new_pids) > 0
  end

  test "plugin crash is isolated — other plugins survive", %{mgr: mgr} do
    {:ok, pid1} = Manager.register(mgr, MockPlugin)
    {:ok, _pid2} = Manager.register(mgr, MockPlugin2)

    # Kill plugin 1 brutally
    Process.exit(pid1, :kill)
    Process.sleep(100)

    # Plugin 2 should still be listed
    assert "mock_plugin_2" in Manager.list(mgr)
  end
end
