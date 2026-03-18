defmodule Kyber.Plugin.Exo do
  @moduledoc """
  Exo distributed inference bridge plugin.

  A lightweight plugin stub for integrating with the `exo` framework
  (https://github.com/exo-explore/exo), which runs LLM inference across
  a cluster of consumer devices (Mac Mini cluster, etc.).

  ## Current capabilities

  - Discovers whether an exo cluster is running locally
  - Queries available models, active nodes, and memory pool size
  - Reports status via `get_inference_status/0`

  ## Future (not yet implemented)

  - Route LLM calls through exo when local models are available
  - Prefer local inference over Anthropic API when latency allows
  - Load balance across exo nodes

  ## Configuration

  By default, checks `http://localhost:52415` (exo's default port).
  Override via opts: `{Kyber.Plugin.Exo, exo_url: "http://192.168.1.10:52415"}`

  ## Usage

      {:ok, _pid} = Kyber.Core.register_plugin(Kyber.Plugin.Exo)

      case Kyber.Plugin.Exo.get_inference_status() do
        {:ok, status} -> IO.inspect(status)
        {:error, :not_available} -> IO.puts("exo not running")
      end
  """

  use GenServer
  require Logger

  @default_exo_url "http://localhost:52415"
  @poll_interval_ms 30_000

  @type inference_status :: %{
          available: boolean(),
          models: [String.t()],
          nodes: [map()],
          memory_pool_gb: float() | nil,
          url: String.t()
        }

  # ── Plugin behaviour ──────────────────────────────────────────────────────

  def name, do: "exo"

  # ── Public API ────────────────────────────────────────────────────────────

  @doc "Start the Exo bridge plugin."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Get the current inference status from the exo cluster.

  Returns `{:ok, status_map}` if exo is reachable, `{:error, :not_available}` otherwise.
  """
  @spec get_inference_status(GenServer.server()) ::
          {:ok, inference_status()} | {:error, :not_available}
  def get_inference_status(server \\ __MODULE__) do
    GenServer.call(server, :get_status)
  end

  @doc "Force a status refresh (normally happens on a 30s timer)."
  @spec refresh(GenServer.server()) :: :ok
  def refresh(server \\ __MODULE__) do
    GenServer.cast(server, :refresh)
  end

  # ── GenServer callbacks ───────────────────────────────────────────────────

  @impl true
  def init(opts) do
    exo_url = Keyword.get(opts, :exo_url, @default_exo_url)
    http_client = Keyword.get(opts, :http_client, &default_http_get/1)

    # Initial discovery
    state = %{
      exo_url: exo_url,
      http_client: http_client,
      status: nil,
      last_check: nil
    }

    # Poll immediately, then on schedule
    send(self(), :poll)
    {:ok, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    case state.status do
      nil -> {:reply, {:error, :not_available}, state}
      status -> {:reply, {:ok, status}, state}
    end
  end

  @impl true
  def handle_cast(:refresh, state) do
    new_state = do_poll(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(:poll, state) do
    new_state = do_poll(state)
    Process.send_after(self(), :poll, @poll_interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ── Private ───────────────────────────────────────────────────────────────

  defp do_poll(state) do
    status = fetch_exo_status(state.exo_url, state.http_client)
    now = System.system_time(:millisecond)

    if status do
      Logger.debug("[Kyber.Plugin.Exo] exo available: #{inspect(Map.take(status, [:models, :nodes]))}")
    end

    %{state | status: status, last_check: now}
  end

  defp fetch_exo_status(url, http_client) do
    # Try /v1/models (OpenAI-compatible endpoint that exo exposes)
    models_url = url <> "/v1/models"
    nodes_url = url <> "/api/v0/nodes"

    with {:ok, models_body} <- http_client.(models_url),
         {:ok, models_data} <- Jason.decode(models_body) do
      models = parse_models(models_data)
      nodes = fetch_nodes(nodes_url, http_client)
      memory_gb = estimate_memory(nodes)

      %{
        available: true,
        models: models,
        nodes: nodes,
        memory_pool_gb: memory_gb,
        url: url
      }
    else
      _ -> nil
    end
  end

  defp fetch_nodes(url, http_client) do
    case http_client.(url) do
      {:ok, body} ->
        case Jason.decode(body) do
          {:ok, nodes} when is_list(nodes) -> nodes
          _ -> []
        end

      _ ->
        []
    end
  end

  defp parse_models(%{"data" => models}) when is_list(models) do
    Enum.map(models, fn m -> Map.get(m, "id", "unknown") end)
  end

  defp parse_models(_), do: []

  defp estimate_memory([]), do: nil

  defp estimate_memory(nodes) do
    total_bytes =
      Enum.reduce(nodes, 0, fn node, acc ->
        acc + Map.get(node, "memory", 0)
      end)

    if total_bytes > 0 do
      Float.round(total_bytes / (1024 * 1024 * 1024), 2)
    else
      nil
    end
  end

  defp default_http_get(url) do
    case Req.get(url, receive_timeout: 5_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} -> {:ok, Jason.encode!(body)}
      _ -> {:error, :request_failed}
    end
  rescue
    _ -> {:error, :request_failed}
  end
end
