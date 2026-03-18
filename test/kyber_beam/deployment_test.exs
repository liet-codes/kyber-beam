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

  describe "deploy/2" do
    test "returns {:error, _} for a nonexistent git ref", %{dep: dep} do
      result = Kyber.Deployment.deploy(dep, "definitely-not-a-real-ref-xyz123abc")
      assert match?({:error, _}, result)
    end
  end
end
