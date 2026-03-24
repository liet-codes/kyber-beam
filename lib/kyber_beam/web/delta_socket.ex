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
