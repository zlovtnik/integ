defmodule GprintExWeb.HealthControllerTest do
  use ExUnit.Case, async: true
  use Plug.Test

  alias GprintExWeb.Router

  @opts Router.init([])

  describe "GET /api/health" do
    test "returns healthy status" do
      conn =
        conn(:get, "/api/health")
        |> Router.call(@opts)

      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "healthy"
      assert body["service"] == "gprint_ex"
      assert Map.has_key?(body, "timestamp")
    end
  end

  describe "GET /api/health/live" do
    test "returns alive status" do
      conn =
        conn(:get, "/api/health/live")
        |> Router.call(@opts)

      assert conn.status == 200

      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "alive"
    end
  end
end
