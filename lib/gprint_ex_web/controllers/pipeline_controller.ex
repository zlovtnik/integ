defmodule GprintExWeb.PipelineController do
  @moduledoc """
  Controller for ETL pipeline management.

  Handles pipeline execution, status tracking, and template management.
  """

  use Phoenix.Controller, formats: [:json]

  alias GprintEx.Boundaries.Pipelines
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  @doc """
  List available pipeline templates.
  GET /api/v1/pipelines/templates
  """
  def templates(conn, _params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, templates} <- Pipelines.list_templates(ctx) do
      json(conn, %{success: true, data: templates})
    end
  end

  @doc """
  Run a pipeline.
  POST /api/v1/pipelines/:name/run
  """
  def run(conn, %{"name" => pipeline_name} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- Pipelines.run(ctx, pipeline_name, params) do
      conn
      |> put_status(:accepted)
      |> json(%{success: true, data: result})
    end
  end

  @doc """
  Get pipeline status by session ID.
  GET /api/v1/pipelines/status/:session_id
  """
  def status(conn, %{"session_id" => session_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, status} <- Pipelines.get_status(ctx, session_id) do
      json(conn, %{success: true, data: status})
    end
  end

  @doc """
  Cancel a running pipeline.
  DELETE /api/v1/pipelines/:session_id
  """
  def cancel(conn, %{"session_id" => session_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with :ok <- Pipelines.cancel(ctx, session_id) do
      json(conn, %{success: true, message: "Pipeline cancelled"})
    end
  end
end
