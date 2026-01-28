defmodule GprintExWeb.ETLSessionController do
  @moduledoc """
  Controller for ETL session management.

  Handles staging session lifecycle: create, load, transform, validate, promote, rollback.
  """

  use Phoenix.Controller, formats: [:json]

  alias GprintEx.Boundaries.ETLSessions
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  @doc """
  List ETL sessions.
  GET /api/v1/etl/sessions
  """
  def index(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, sessions} <- ETLSessions.list(ctx, params) do
      json(conn, %{success: true, data: sessions})
    end
  end

  @doc """
  Create a new ETL session.
  POST /api/v1/etl/sessions
  """
  def create(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, session} <- ETLSessions.create(ctx, params) do
      conn
      |> put_status(:created)
      |> json(%{success: true, data: session})
    end
  end

  @doc """
  Get session status.
  GET /api/v1/etl/sessions/:id
  """
  def show(conn, %{"id" => session_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, session} <- ETLSessions.get(ctx, session_id) do
      json(conn, %{success: true, data: session})
    end
  end

  @doc """
  Load data to staging session.
  POST /api/v1/etl/sessions/:id/load
  """
  def load(conn, %{"id" => session_id} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- ETLSessions.load_data(ctx, session_id, params) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Transform staging data.
  POST /api/v1/etl/sessions/:id/transform
  """
  def transform(conn, %{"id" => session_id} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- ETLSessions.transform(ctx, session_id, params) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Validate staging data.
  POST /api/v1/etl/sessions/:id/validate
  """
  def validate(conn, %{"id" => session_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- ETLSessions.validate(ctx, session_id) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Promote staging data to production.
  POST /api/v1/etl/sessions/:id/promote
  """
  def promote(conn, %{"id" => session_id} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- ETLSessions.promote(ctx, session_id, params) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Rollback/cancel a staging session.
  DELETE /api/v1/etl/sessions/:id
  """
  def delete(conn, %{"id" => session_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- ETLSessions.rollback(ctx, session_id) do
      json(conn, %{success: true, data: result, message: "Session rolled back"})
    end
  end

  @doc """
  Cleanup old sessions (admin).
  POST /api/v1/etl/cleanup
  """
  def cleanup(conn, params) do
    ctx = AuthPlug.tenant_context(conn)
    retention_days = Map.get(params, "retention_days", 30)

    with {:ok, count} <- ETLSessions.cleanup(ctx, retention_days) do
      json(conn, %{success: true, data: %{cleaned_sessions: count}})
    end
  end
end
