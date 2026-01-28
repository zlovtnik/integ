defmodule GprintExWeb.IntegrationMessageController do
  @moduledoc """
  Controller for integration message management.

  Handles EIP message routing, transformation, deduplication, and aggregation.
  """

  use Phoenix.Controller, formats: [:json]

  alias GprintEx.Boundaries.IntegrationMessages
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  @doc """
  Submit a new integration message.
  POST /api/v1/integration/messages
  """
  def create(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- IntegrationMessages.submit(ctx, params) do
      conn
      |> put_status(:created)
      |> json(%{success: true, data: result})
    end
  end

  @doc """
  Transform a message to target format.
  POST /api/v1/integration/messages/transform
  """
  def transform(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- IntegrationMessages.transform(ctx, params) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Check if message is duplicate.
  POST /api/v1/integration/messages/check-duplicate
  """
  def check_duplicate(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, is_duplicate} <- IntegrationMessages.check_duplicate(ctx, params) do
      json(conn, %{success: true, data: %{is_duplicate: is_duplicate}})
    end
  end

  @doc """
  Mark message as processed.
  POST /api/v1/integration/messages/:id/processed
  """
  def mark_processed(conn, %{"id" => message_id} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with :ok <- IntegrationMessages.mark_processed(ctx, message_id, params) do
      json(conn, %{success: true, message: "Message marked as processed"})
    end
  end

  @doc """
  Retry a failed message.
  POST /api/v1/integration/messages/:id/retry
  """
  def retry(conn, %{"id" => message_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- IntegrationMessages.retry(ctx, parse_int(message_id)) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Move message to dead letter queue.
  POST /api/v1/integration/messages/:id/dead-letter
  """
  def dead_letter(conn, %{"id" => message_id} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with :ok <- IntegrationMessages.dead_letter(ctx, parse_int(message_id), params) do
      json(conn, %{success: true, message: "Message moved to dead letter queue"})
    end
  end

  @doc """
  Get routing rules.
  GET /api/v1/integration/routing-rules
  """
  def routing_rules(conn, _params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, rules} <- IntegrationMessages.get_routing_rules(ctx) do
      json(conn, %{success: true, data: rules})
    end
  end

  # Aggregation endpoints

  @doc """
  Start a message aggregation.
  POST /api/v1/integration/aggregations
  """
  def start_aggregation(conn, params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- IntegrationMessages.start_aggregation(ctx, params) do
      conn
      |> put_status(:created)
      |> json(%{success: true, data: result})
    end
  end

  @doc """
  Add message to aggregation.
  POST /api/v1/integration/aggregations/:id/messages
  """
  def add_to_aggregation(conn, %{"id" => aggregation_id} = params) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- IntegrationMessages.add_to_aggregation(ctx, parse_int(aggregation_id), params) do
      json(conn, %{success: true, data: result})
    end
  end

  @doc """
  Complete aggregation and get result.
  POST /api/v1/integration/aggregations/:id/complete
  """
  def complete_aggregation(conn, %{"id" => aggregation_id}) do
    ctx = AuthPlug.tenant_context(conn)

    with {:ok, result} <- IntegrationMessages.complete_aggregation(ctx, parse_int(aggregation_id)) do
      json(conn, %{success: true, data: result})
    end
  end

  defp parse_int(value) when is_integer(value), do: value
  defp parse_int(value) when is_binary(value), do: String.to_integer(value)
end
