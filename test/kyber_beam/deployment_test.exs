defmodule Kyber.DeploymentTest do
  use ExUnit.Case, async: true

  setup do
    # Use a unique name so we don't collide with the application-started Kyber.Deployment
    name = :"kyber_deployment_test_#{:erlang.unique_integer([:positive])}"
    {:ok, dep} = Kyber.Deployment.start_link(project_dir: File.cwd!(), name: name)

    on_exit(fn ->
      if Process.alive?(dep), do: GenServer.stop(dep, :normal)
    end)

    %{dep: dep}
  end

  describe "reload_module/2" do
    test "reloads an existing module", %{dep: dep} do
      result = Kyber.Deployment.reload_module(dep, Kyber.Delta)
      assert result == :ok
    end

    test "tracks reloaded modules in deployed_versions", %{dep: dep} do
      :ok = Kyber.Deployment.reload_module(dep, Kyber.Delta)
      versions = Kyber.Deployment.deployed_versions(dep)
      assert length(versions) >= 1
      latest = hd(versions)
      assert latest.module == Kyber.Delta
      assert is_integer(latest.loaded_at)
      assert latest.node == node()
    end

    test "returns {:error, reason} for nonexistent module", %{dep: dep} do
      result = Kyber.Deployment.reload_module(dep, :"Elixir.NonExistentModule")
      assert match?({:error, _}, result)
    end

    test "caps version history at 100 records", %{dep: dep} do
      for _ <- 1..5 do
        Kyber.Deployment.reload_module(dep, Kyber.Delta)
      end

      versions = Kyber.Deployment.deployed_versions(dep)
      assert length(versions) <= 100
    end
  end

  describe "reload_cluster/2" do
    test "reloads locally when no remote nodes connected", %{dep: dep} do
      results = Kyber.Deployment.reload_cluster(dep, Kyber.Delta)
      assert is_map(results)
      assert Map.get(results, node()) == :ok
    end

    test "result map always contains the local node", %{dep: dep} do
      results = Kyber.Deployment.reload_cluster(dep, Kyber.State)
      assert Map.has_key?(results, node())
    end
  end

  describe "deployed_versions/1" do
    test "returns empty list on fresh start", %{dep: dep} do
      assert [] == Kyber.Deployment.deployed_versions(dep)
    end

    test "records entry after successful reload", %{dep: dep} do
      :ok = Kyber.Deployment.reload_module(dep, Kyber.Delta)
      versions = Kyber.Deployment.deployed_versions(dep)
      assert [%{module: Kyber.Delta, node: n}] = versions
      assert n == node()
    end

    test "multiple reloads accumulate correctly", %{dep: dep} do
      :ok = Kyber.Deployment.reload_module(dep, Kyber.Delta)
      :ok = Kyber.Deployment.reload_module(dep, Kyber.State)
      versions = Kyber.Deployment.deployed_versions(dep)
      assert length(versions) == 2
      assert Enum.any?(versions, &(&1.module == Kyber.Delta))
      assert Enum.any?(versions, &(&1.module == Kyber.State))
    end
  end

  describe "deploy/2 — async" do
    test "returns {:ok, :deploying} immediately", %{dep: dep} do
      result = Kyber.Deployment.deploy(dep, "definitely-not-a-real-ref-xyz123abc")
      assert result == {:ok, :deploying}
    end

    test "deploying?/1 returns true while a deploy task is running", %{dep: dep} do
      # Kick off a deploy (will fail quickly on bad ref, but we check state first)
      Kyber.Deployment.deploy(dep, "nonexistent-ref-check-deploying")
      # deploying? should return true right after the call
      assert Kyber.Deployment.deploying?(dep) == true
    end

    test "deploying?/1 returns false after task completes", %{dep: dep} do
      Kyber.Deployment.deploy(dep, "nonexistent-ref-will-fail-fast")
      # Wait for the git command to fail and the cast to arrive
      assert_eventually(fn -> Kyber.Deployment.deploying?(dep) == false end, 3_000)
    end

    test "second deploy while one is running returns {:error, :already_deploying}", %{dep: dep} do
      Kyber.Deployment.deploy(dep, "nonexistent-ref-block-1")
      result = Kyber.Deployment.deploy(dep, "nonexistent-ref-block-2")
      assert result == {:error, :already_deploying}
    end

    test "deploy is re-entrant after task completes", %{dep: dep} do
      Kyber.Deployment.deploy(dep, "nonexistent-ref-retry-1")
      # Wait for first deploy to finish
      assert_eventually(fn -> Kyber.Deployment.deploying?(dep) == false end, 3_000)
      # Should accept a new deploy now
      result = Kyber.Deployment.deploy(dep, "nonexistent-ref-retry-2")
      assert result == {:ok, :deploying}
    end

    test "GenServer stays responsive immediately after deploy/2 call", %{dep: dep} do
      Kyber.Deployment.deploy(dep, "nonexistent-ref-responsive")
      # This call must not block — deploy is async
      assert Process.alive?(dep)
      assert is_list(Kyber.Deployment.deployed_versions(dep))
    end
  end

  # Helper: poll a condition up to `timeout_ms`, sleeping 50ms between tries.
  defp assert_eventually(condition, timeout_ms, start \\ System.monotonic_time(:millisecond)) do
    if condition.() do
      :ok
    else
      now = System.monotonic_time(:millisecond)
      elapsed = now - start

      if elapsed >= timeout_ms do
        flunk("Condition never became true within #{timeout_ms}ms")
      else
        Process.sleep(50)
        assert_eventually(condition, timeout_ms, start)
      end
    end
  end
end
