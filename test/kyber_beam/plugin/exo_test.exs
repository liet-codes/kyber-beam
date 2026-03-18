defmodule Kyber.Plugin.ExoTest do
  use ExUnit.Case, async: true

  defp unique_exo_name, do: :"kyber_exo_test_#{:erlang.unique_integer([:positive])}"

  def mock_client_available(_url) do
    body = %{
      "data" => [
        %{"id" => "llama-3.1-8b", "object" => "model"},
        %{"id" => "mistral-7b", "object" => "model"}
      ]
    }
    {:ok, Jason.encode!(body)}
  end

  def mock_client_unavailable(_url), do: {:error, :request_failed}

  def mock_client_with_nodes(url) do
    cond do
      String.ends_with?(url, "/v1/models") ->
        {:ok, Jason.encode!(%{"data" => [%{"id" => "llama-3.1-8b"}]})}

      String.ends_with?(url, "/api/v0/nodes") ->
        nodes = [
          %{"id" => "node1", "memory" => 16 * 1024 * 1024 * 1024},
          %{"id" => "node2", "memory" => 8 * 1024 * 1024 * 1024}
        ]
        {:ok, Jason.encode!(nodes)}

      true ->
        {:error, :request_failed}
    end
  end

  defp start_exo(http_client, opts \\ []) do
    name = unique_exo_name()
    full_opts = [http_client: http_client, exo_url: "http://localhost:52415", name: name] ++ opts
    {:ok, pid} = Kyber.Plugin.Exo.start_link(full_opts)
    Process.unlink(pid)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid, :normal) end)
    pid
  end

  describe "name/0" do
    test "returns plugin name" do
      assert Kyber.Plugin.Exo.name() == "exo"
    end
  end

  describe "get_inference_status/1" do
    test "returns available status when exo responds" do
      exo = start_exo(&mock_client_available/1)
      Process.sleep(100)

      assert {:ok, status} = Kyber.Plugin.Exo.get_inference_status(exo)
      assert status.available == true
      assert is_list(status.models)
      assert "llama-3.1-8b" in status.models
      assert "mistral-7b" in status.models
    end

    test "returns {:error, :not_available} when exo is down" do
      exo = start_exo(&mock_client_unavailable/1)
      Process.sleep(100)

      assert Kyber.Plugin.Exo.get_inference_status(exo) == {:error, :not_available}
    end

    test "includes node and memory info when nodes available" do
      exo = start_exo(&mock_client_with_nodes/1)
      Process.sleep(100)

      assert {:ok, status} = Kyber.Plugin.Exo.get_inference_status(exo)
      assert status.available == true
      assert length(status.nodes) == 2
      assert status.memory_pool_gb == 24.0
    end
  end

  describe "refresh/1" do
    test "forces a status refresh without crashing" do
      exo = start_exo(&mock_client_available/1)
      Process.sleep(100)
      assert :ok = Kyber.Plugin.Exo.refresh(exo)
      Process.sleep(100)
      assert {:ok, _} = Kyber.Plugin.Exo.get_inference_status(exo)
    end
  end

  describe "plugin lifecycle" do
    test "starts and stops cleanly" do
      exo = start_exo(&mock_client_available/1)
      assert Process.alive?(exo)
      GenServer.stop(exo, :normal)
      Process.sleep(50)
      refute Process.alive?(exo)
    end

    test "handles unexpected messages gracefully" do
      exo = start_exo(&mock_client_available/1)
      send(exo, :unexpected_message)
      Process.sleep(50)
      assert Process.alive?(exo)
    end
  end

  describe "model parsing edge cases" do
    test "handles empty model list" do
      empty_client = fn _url -> {:ok, Jason.encode!(%{"data" => []})} end
      exo = start_exo(empty_client)
      Process.sleep(100)

      assert {:ok, status} = Kyber.Plugin.Exo.get_inference_status(exo)
      assert status.models == []
      assert status.available == true
    end

    test "handles malformed JSON response gracefully" do
      bad_client = fn _url -> {:ok, "not json {{{"} end
      exo = start_exo(bad_client)
      Process.sleep(100)

      assert Kyber.Plugin.Exo.get_inference_status(exo) == {:error, :not_available}
    end

    test "nil memory_pool when nodes have no memory field" do
      client = fn url ->
        cond do
          String.ends_with?(url, "/v1/models") ->
            {:ok, Jason.encode!(%{"data" => [%{"id" => "test-model"}]})}
          String.ends_with?(url, "/api/v0/nodes") ->
            {:ok, Jason.encode!([%{"id" => "node1"}])}
          true ->
            {:error, :request_failed}
        end
      end

      exo = start_exo(client)
      Process.sleep(100)

      assert {:ok, status} = Kyber.Plugin.Exo.get_inference_status(exo)
      assert status.memory_pool_gb == nil
    end
  end
end
