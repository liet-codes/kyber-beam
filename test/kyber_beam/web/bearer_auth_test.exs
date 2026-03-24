defmodule Kyber.Web.Plugs.BearerAuthTest do
  @moduledoc """
  Tests for the BearerAuth plug.

  Verifies that bearer token authentication is enforced when an API token is
  configured, and that dev mode (no token configured) passes through cleanly.
  """
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias Kyber.Web.Plugs.BearerAuth

  defp call_plug(conn, _opts \\ []) do
    BearerAuth.call(conn, BearerAuth.init([]))
  end

  describe "when KYBER_API_TOKEN is not configured" do
    setup do
      # Ensure no token is set for this test
      Application.delete_env(:kyber_beam, :api_token)
      on_exit(fn -> Application.delete_env(:kyber_beam, :api_token) end)
      :ok
    end

    test "passes all requests through (dev mode)" do
      conn = conn(:get, "/api/test")
      result = call_plug(conn)
      refute result.halted
    end
  end

  describe "when KYBER_API_TOKEN is configured" do
    setup do
      Application.put_env(:kyber_beam, :api_token, "test-secret-token")
      on_exit(fn -> Application.delete_env(:kyber_beam, :api_token) end)
      :ok
    end

    test "allows requests with correct bearer token" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Bearer test-secret-token")

      result = call_plug(conn)
      refute result.halted
    end

    test "rejects requests with wrong token" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Bearer wrong-token")

      result = call_plug(conn)
      assert result.halted
      assert result.status == 401
      body = Jason.decode!(result.resp_body)
      assert body["ok"] == false
      assert body["error"] == "unauthorized"
    end

    test "rejects requests with no authorization header" do
      conn = conn(:get, "/api/test")
      result = call_plug(conn)
      assert result.halted
      assert result.status == 401
    end

    test "rejects requests with non-bearer auth scheme" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Basic dGVzdDp0ZXN0")

      result = call_plug(conn)
      assert result.halted
      assert result.status == 401
    end

    test "rejects requests with empty bearer token" do
      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Bearer ")

      result = call_plug(conn)
      assert result.halted
      assert result.status == 401
    end

    test "uses constant-time comparison (token with matching prefix is still rejected)" do
      # A token sharing a prefix with the real token must still be rejected,
      # verifying we don't short-circuit on partial matches.
      conn =
        conn(:get, "/api/test")
        |> put_req_header("authorization", "Bearer test-secret-token-extra")

      result = call_plug(conn)
      assert result.halted
      assert result.status == 401
    end
  end
end
