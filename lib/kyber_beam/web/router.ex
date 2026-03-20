defmodule Kyber.Web.Router do
  @moduledoc """
  HTTP/WebSocket router for the Kyber BEAM API.

  Routes:
  - `GET  /health`      → `{"status":"ok"}`
  - `GET  /api/deltas`  → JSON array of deltas (filters: since, kind, limit)
  - `POST /api/deltas`  → emit a new delta from JSON body → `{"ok":true,"id":"..."}`
  - `GET  /ws`          → WebSocket upgrade — broadcasts new deltas via PubSub

  Uses Plug.Router + Bandit as HTTP server. WebSocket via WebSockAdapter.
  """

  use Plug.Router

  plug(Plug.Logger)
  plug(:match)
  plug(Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason
  )
  plug(:dispatch)

  # ── Routes ─────────────────────────────────────────────────────────────────

  get "/health" do
    send_json(conn, 200, %{status: "ok"})
  end

  get "/api/deltas" do
    filters = build_filters(conn.query_params)
    store = store_pid()
    deltas = Kyber.Delta.Store.query(store, filters)
    payload = Enum.map(deltas, &Kyber.Delta.to_map/1)
    send_json(conn, 200, %{ok: true, deltas: payload})
  end

  post "/api/deltas" do
    body = conn.body_params

    with {:ok, kind} <- Map.fetch(body, "kind") do
      origin = parse_origin(Map.get(body, "origin", %{"type" => "system", "reason" => "api"}))
      payload = Map.get(body, "payload", %{})
      parent_id = Map.get(body, "parent_id")

      delta = Kyber.Delta.new(kind, payload, origin, parent_id)
      store = store_pid()
      :ok = Kyber.Delta.Store.append(store, delta)
      send_json(conn, 201, %{ok: true, id: delta.id})
    else
      :error ->
        send_json(conn, 400, %{ok: false, error: "missing required field: kind"})
    end
  end

  get "/ws" do
    conn
    |> WebSockAdapter.upgrade(Kyber.Web.DeltaSocket, %{store: store_pid()}, timeout: 60_000)
    |> halt()
  end

  match _ do
    send_json(conn, 404, %{ok: false, error: "not found"})
  end

  # ── Helpers ────────────────────────────────────────────────────────────────

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end

  defp build_filters(params) do
    []
    |> maybe_put(:since, params["since"], &String.to_integer/1)
    |> maybe_put(:kind, params["kind"])
    |> maybe_put(:limit, params["limit"], &String.to_integer/1)
  end

  defp maybe_put(filters, _key, nil), do: filters
  defp maybe_put(filters, key, value), do: Keyword.put(filters, key, value)

  defp maybe_put(filters, _key, nil, _transform), do: filters

  defp maybe_put(filters, key, value, transform) do
    try do
      Keyword.put(filters, key, transform.(value))
    rescue
      _ -> filters
    end
  end

  defp parse_origin(map) when is_map(map) do
    Kyber.Delta.Origin.deserialize(map)
  end

  defp parse_origin(_), do: {:system, "api"}

  defp store_pid do
    # In production, look up the registered store.
    # In tests, this can be overridden by process dictionary.
    # The Core supervisor registers the store as :"Elixir.Kyber.Core.Store"
    # (derived from the core name), not as Kyber.Delta.Store.
    Process.get(:kyber_store_pid) || :"Elixir.Kyber.Core.Store"
  end
end

defmodule Kyber.Web.DeltaSocket do
  @moduledoc """
  WebSocket handler that streams new deltas to connected clients.

  On connect, subscribes to the Delta.Store PubSub. Each new delta is
  serialized as JSON and sent to the client. On disconnect, unsubscribes.
  """

  @behaviour WebSock
  require Logger

  @impl true
  def init(%{store: store}) do
    # Capture ws_pid BEFORE the subscribe call. The subscribe callback is
    # invoked from a Task spawned by Delta.Store.broadcast/2 — if we called
    # self() inside the closure, it would return the Task's PID, not ours,
    # and the {:delta, delta} message would be sent to the wrong process.
    ws_pid = self()

    unsubscribe_fn = Kyber.Delta.Store.subscribe(store, fn delta ->
      send(ws_pid, {:delta, delta})
    end)

    {:ok, %{unsubscribe_fn: unsubscribe_fn}}
  end

  @impl true
  def handle_in({_text, _opts}, state) do
    # Ignore incoming messages from client for now
    {:ok, state}
  end

  @impl true
  def handle_info({:delta, delta}, state) do
    payload = Jason.encode!(Kyber.Delta.to_map(delta))
    {:push, [{:text, payload}], state}
  end

  def handle_info(_msg, state) do
    {:ok, state}
  end

  @impl true
  def terminate(_reason, %{unsubscribe_fn: unsubscribe_fn}) do
    unsubscribe_fn.()
    :ok
  end

  def terminate(_reason, _state), do: :ok
end

defmodule Kyber.Web.Server do
  @moduledoc "Starts the Bandit HTTP server serving Kyber.Web.Router."

  def child_spec(opts) do
    port = Keyword.get(opts, :port, 4000)

    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [port]},
      type: :worker,
      restart: :permanent
    }
  end

  def start_link(port) do
    Bandit.start_link(plug: Kyber.Web.Router, port: port)
  end
end
