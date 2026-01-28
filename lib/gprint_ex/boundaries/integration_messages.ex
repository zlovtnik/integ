defmodule GprintEx.Boundaries.IntegrationMessages do
  @moduledoc """
  Boundary for integration message management.

  Handles EIP message routing, transformation, deduplication, and aggregation.
  """

  alias GprintEx.Integration.Message
  alias GprintEx.Integration.DB.IntegrationOperations

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @doc """
  Submit a new integration message for processing.
  """
  @spec submit(tenant_context(), map()) :: {:ok, map()} | {:error, term()}
  def submit(%{tenant_id: _tenant_id, user: user}, params) do
    with {:ok, message} <- build_message(params),
         {:ok, false} <- check_duplicate(message),
         {:ok, destination} <- IntegrationOperations.route_message(message),
         {:ok, log_id} <- IntegrationOperations.log_message(message, "ROUTED") do
      {:ok, %{
        message_id: message.id,
        log_id: log_id,
        destination: destination,
        status: "ROUTED",
        processed_by: user
      }}
    else
      {:ok, true} -> {:error, :duplicate_message}
      error -> error
    end
  end

  @doc """
  Transform a message to a target format.
  """
  @spec transform(tenant_context(), map()) :: {:ok, map()} | {:error, term()}
  def transform(%{tenant_id: _tenant_id}, %{"message" => message_params, "target_format" => target_format}) do
    with {:ok, message} <- build_message(message_params),
         {:ok, transformed} <- IntegrationOperations.transform_message(message, target_format) do
      {:ok, %{
        message_id: transformed.id,
        payload: transformed.payload,
        format: target_format
      }}
    end
  end

  def transform(_ctx, _params), do: {:error, :validation_failed, ["message and target_format required"]}

  @doc """
  Check if a message is a duplicate.
  """
  @spec check_duplicate(tenant_context(), map()) :: {:ok, boolean()} | {:error, term()}
  def check_duplicate(%{tenant_id: _tenant_id}, %{"message_id" => message_id, "hash" => hash}) do
    window = Map.get(%{}, "window_minutes", 60)
    IntegrationOperations.is_duplicate?(message_id, hash, window)
  end

  def check_duplicate(_ctx, _params), do: {:error, :validation_failed, ["message_id and hash required"]}

  @doc """
  Mark a message as processed.
  """
  @spec mark_processed(tenant_context(), String.t(), map()) :: :ok | {:error, term()}
  def mark_processed(%{tenant_id: _tenant_id, user: user}, message_id, %{"hash" => hash}) do
    IntegrationOperations.mark_processed(message_id, hash, user)
  end

  def mark_processed(_ctx, _message_id, _params), do: {:error, :validation_failed, ["hash required"]}

  @doc """
  Retry a failed message.
  """
  @spec retry(tenant_context(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def retry(%{tenant_id: _tenant_id}, message_id) do
    case IntegrationOperations.retry_message(message_id) do
      {:ok, next_retry} -> {:ok, %{message_id: message_id, next_retry_at: next_retry}}
      {:error, :max_retries} -> {:error, :max_retries_exceeded}
      error -> error
    end
  end

  @doc """
  Move message to dead letter queue.
  """
  @spec dead_letter(tenant_context(), pos_integer(), map()) :: :ok | {:error, term()}
  def dead_letter(%{tenant_id: _tenant_id}, message_id, %{"reason" => reason}) do
    IntegrationOperations.move_to_dead_letter(message_id, reason)
  end

  def dead_letter(_ctx, _message_id, _params), do: {:error, :validation_failed, ["reason required"]}

  @doc """
  Get routing rules.
  """
  @spec get_routing_rules(tenant_context()) :: {:ok, [map()]} | {:error, term()}
  def get_routing_rules(%{tenant_id: tenant_id}) do
    IntegrationOperations.get_routing_rules(tenant_id)
  end

  # Aggregation operations

  @doc """
  Start a message aggregation.
  """
  @spec start_aggregation(tenant_context(), map()) :: {:ok, map()} | {:error, term()}
  def start_aggregation(%{tenant_id: _tenant_id}, params) do
    with {:ok, correlation_id} <- get_required(params, "correlation_id"),
         {:ok, aggregation_type} <- get_required(params, "aggregation_type"),
         {:ok, expected_count} <- get_required(params, "expected_count"),
         timeout <- Map.get(params, "timeout_minutes", 30),
         {:ok, id} <- IntegrationOperations.start_aggregation(correlation_id, aggregation_type, expected_count, timeout) do
      {:ok, %{
        aggregation_id: id,
        correlation_id: correlation_id,
        aggregation_type: aggregation_type,
        expected_count: expected_count,
        timeout_minutes: timeout
      }}
    end
  end

  @doc """
  Add a message to an aggregation.
  """
  @spec add_to_aggregation(tenant_context(), pos_integer(), map()) :: {:ok, map()} | {:error, term()}
  def add_to_aggregation(%{tenant_id: _tenant_id}, aggregation_id, %{"payload" => payload}) do
    case IntegrationOperations.add_to_aggregation(aggregation_id, payload) do
      {:ok, is_complete} ->
        {:ok, %{aggregation_id: aggregation_id, is_complete: is_complete}}
      error -> error
    end
  end

  def add_to_aggregation(_ctx, _id, _params), do: {:error, :validation_failed, ["payload required"]}

  @doc """
  Complete an aggregation and get combined result.
  """
  @spec complete_aggregation(tenant_context(), pos_integer()) :: {:ok, term()} | {:error, term()}
  def complete_aggregation(%{tenant_id: _tenant_id}, aggregation_id) do
    IntegrationOperations.complete_aggregation(aggregation_id)
  end

  # Private helpers

  defp build_message(params) do
    message_type = params["message_type"]
    payload = params["payload"]

    if message_type && payload do
      Message.new(message_type, payload,
        source_system: params["source_system"],
        routing_key: params["routing_key"],
        correlation_id: params["correlation_id"]
      )
    else
      {:error, :validation_failed, ["message_type and payload are required"]}
    end
  end

  defp check_duplicate(%Message{id: id} = message) do
    hash = :crypto.hash(:sha256, Jason.encode!(message.payload)) |> Base.encode16()
    IntegrationOperations.is_duplicate?(id, hash, 60)
  end

  defp get_required(params, key) do
    case Map.get(params, key) do
      nil -> {:error, :validation_failed, ["#{key} is required"]}
      value -> {:ok, value}
    end
  end
end
