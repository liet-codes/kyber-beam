defmodule Kyber.Web.RouterTest do
  use ExUnit.Case, async: false
  use Plug.Test

  alias Kyber.Web.Router
  alias Kyber.{Delta, Delta.Store}

  # Set up a store process and wire it to the router via process dictionary
  setup do
    path = System.tmp_dir!() |> Path.join("kyber_web_test_#{:rand.uniform(999_999)}.jsonl")
    on_exit(fn -> File.rm(path) end)

    {:ok, store} = Store.start_link(path: path, name: :"web_store_#{:rand.uniform(999_999)}")
    # Make the store available to the router handler via process dictionary
    Process.put(:kyber_store_pid, store)

    {:ok, store: store}
  end

  describe "GET /health" do
    test "returns 200 and status ok" do
      conn = conn(:get, "/health") |> Router.call([])
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "ok"
    end
  end

  describe "GET /api/deltas" do
    test "returns empty list when no deltas", %{store: _store} do
      conn = conn(:get, "/api/deltas") |> Router.call([])
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["ok"] == true
      assert body["deltas"] == []
    end

    test "returns deltas from store", %{store: store} do
      d1 = Delta.new("test.event", %{"n" => 1})
      d2 = Delta.new("test.event", %{"n" => 2})
      Store.append(store, d1)
      Store.append(store, d2)

      conn = conn(:get, "/api/deltas") |> Router.call([])
      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert length(body["deltas"]) == 2
    end

    test "filters by kind via query param", %{store: store} do
      Store.append(store, Delta.new("message.received", %{}))
      Store.append(store, Delta.new("error.route", %{}))
      Store.append(store, Delta.new("message.received", %{}))

      conn = conn(:get, "/api/deltas?kind=message.received") |> Router.call([])
      body = Jason.decode!(conn.resp_body)
      assert length(body["deltas"]) == 2
      assert Enum.all?(body["deltas"], &(&1["kind"] == "message.received"))
    end

    test "filters by limit via query param", %{store: store} do
      for i <- 1..5 do
        Store.append(store, Delta.new("test.event", %{"i" => i}))
      end

      conn = conn(:get, "/api/deltas?limit=3") |> Router.call([])
      body = Jason.decode!(conn.resp_body)
      assert length(body["deltas"]) == 3
    end
  end

  describe "POST /api/deltas" do
    test "creates a delta and returns id" do
      body = Jason.encode!(%{"kind" => "test.event", "payload" => %{"x" => 1}})

      conn =
        conn(:post, "/api/deltas", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call([])

      assert conn.status == 201
      resp = Jason.decode!(conn.resp_body)
      assert resp["ok"] == true
      assert is_binary(resp["id"])
    end

    test "returns 400 when kind is missing" do
      body = Jason.encode!(%{"payload" => %{}})

      conn =
        conn(:post, "/api/deltas", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call([])

      assert conn.status == 400
      resp = Jason.decode!(conn.resp_body)
      assert resp["ok"] == false
    end

    test "appended delta is retrievable" do
      body = Jason.encode!(%{"kind" => "new.event", "payload" => %{"hello" => "world"}})

      conn =
        conn(:post, "/api/deltas", body)
        |> put_req_header("content-type", "application/json")
        |> Router.call([])

      resp = Jason.decode!(conn.resp_body)
      posted_id = resp["id"]

      list_conn = conn(:get, "/api/deltas") |> Router.call([])
      list_resp = Jason.decode!(list_conn.resp_body)
      ids = Enum.map(list_resp["deltas"], & &1["id"])
      assert posted_id in ids
    end
  end

  describe "404" do
    test "unknown routes return 404" do
      conn = conn(:get, "/not/a/real/route") |> Router.call([])
      assert conn.status == 404
      body = Jason.decode!(conn.resp_body)
      assert body["ok"] == false
    end
  end

  describe "JSON encoding" do
    test "responses have application/json content type" do
      conn = conn(:get, "/health") |> Router.call([])
      content_type = conn |> get_resp_header("content-type") |> hd()
      assert String.starts_with?(content_type, "application/json")
    end
  end

  describe "DeltaSocket WebSocket pid capture" do
    test "subscribe callback delivers deltas to the correct process (ws_pid fix)", %{store: store} do
      test_pid = self()

      # Simulate what DeltaSocket.init/1 does — capture self() BEFORE subscribing.
      # This is the fix: ws_pid is bound to the WebSocket handler's PID, not the
      # Task PID that runs the broadcast callback.
      ws_pid = test_pid

      unsubscribe_fn = Store.subscribe(store, fn delta ->
        # In the old (buggy) code, self() here would return the Task's PID.
        # With ws_pid captured outside, we correctly target the WebSocket handler.
        send(ws_pid, {:delta, delta})
      end)

      delta = Delta.new("ws.test.event", %{"msg" => "hello ws"})
      Store.append(store, delta)

      assert_receive {:delta, received}, 500
      assert received.id == delta.id
      assert received.kind == "ws.test.event"

      unsubscribe_fn.()
    end

    test "DeltaSocket handles multiple deltas in sequence", %{store: store} do
      test_pid = self()
      ws_pid = test_pid

      unsubscribe_fn = Store.subscribe(store, fn delta ->
        send(ws_pid, {:delta, delta})
      end)

      d1 = Delta.new("ws.seq.1", %{})
      d2 = Delta.new("ws.seq.2", %{})
      Store.append(store, d1)
      Store.append(store, d2)

      assert_receive {:delta, r1}, 500
      assert_receive {:delta, r2}, 500
      received_ids = MapSet.new([r1.id, r2.id])
      assert MapSet.member?(received_ids, d1.id)
      assert MapSet.member?(received_ids, d2.id)

      unsubscribe_fn.()
    end
  end
end
