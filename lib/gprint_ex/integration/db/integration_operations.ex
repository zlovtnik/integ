defmodule GprintEx.Integration.DB.IntegrationOperations do
  @moduledoc """
  Database operations for EIP integration patterns.

  Wraps PL/SQL INTEGRATION_PKG calls for message routing,
  transformation, aggregation, and deduplication.
  """

  require Logger

  alias GprintEx.Integration.Message
  alias GprintEx.Infrastructure.Repo.OracleConnection

  @doc """
  Route a message via INTEGRATION_PKG.route_message.
  """
  @spec route_message(Message.t()) :: {:ok, String.t()} | {:error, term()}
  def route_message(%Message{} = message) do
    sql = """
    DECLARE
      v_msg integration_message_t;
      v_destination VARCHAR2(100);
    BEGIN
      v_msg := integration_message_t(
        :message_id, :correlation_id, :message_type, :source_system,
        :routing_key, :payload, :format, :priority, 0, NULL, NULL
      );
      v_destination := integration_pkg.route_message(v_msg);
      :out := v_destination;
    END;
    """

    params = [
      message_id: message.id,
      correlation_id: message.correlation_id,
      message_type: message.message_type,
      source_system: message.source_system,
      routing_key: message.routing_key,
      payload: Jason.encode!(message.payload),
      format: "JSON",
      priority: message.priority,
      out: {:out, :string}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: destination}} -> {:ok, destination}
      {:ok, [destination]} -> {:ok, destination}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Transform a message via INTEGRATION_PKG.transform_message.
  """
  @spec transform_message(Message.t(), String.t()) :: {:ok, Message.t()} | {:error, term()}
  def transform_message(%Message{} = message, target_format) do
    sql = """
    DECLARE
      v_msg integration_message_t;
      v_result integration_message_t;
      v_payload CLOB;
    BEGIN
      v_msg := integration_message_t(
        :message_id, :correlation_id, :message_type, :source_system,
        :routing_key, :payload, :format, :priority, 0, NULL, NULL
      );
      v_result := integration_pkg.transform_message(v_msg, :target_format);
      v_payload := v_result.payload;
      :out_payload := v_payload;
      :out_format := v_result.format;
    END;
    """

    params = [
      message_id: message.id,
      correlation_id: message.correlation_id,
      message_type: message.message_type,
      source_system: message.source_system,
      routing_key: message.routing_key,
      payload: Jason.encode!(message.payload),
      format: "JSON",
      priority: message.priority,
      target_format: target_format,
      out_payload: {:out, :string},
      out_format: {:out, :string}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out_payload: payload, out_format: format}} ->
        decoded_payload =
          case format do
            "JSON" -> Jason.decode!(payload)
            _ -> payload
          end

        updated = %{message | payload: decoded_payload}
        {:ok, updated}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Check for duplicate message via INTEGRATION_PKG.is_duplicate_message.
  """
  @spec is_duplicate?(String.t(), String.t(), non_neg_integer()) :: boolean()
  def is_duplicate?(message_id, message_hash, window_minutes \\ 60) do
    sql = """
    SELECT integration_pkg.is_duplicate_message(:message_id, :message_hash, :window_minutes)
    FROM DUAL
    """

    params = [message_id, message_hash, window_minutes]

    case OracleConnection.query(:gprint_pool, sql, params) do
      {:ok, [[1]]} -> true
      {:ok, [[0]]} -> false
      _ -> false
    end
  end

  @doc """
  Mark message as processed via INTEGRATION_PKG.mark_message_processed.
  """
  @spec mark_processed(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def mark_processed(message_id, message_hash, processed_by) do
    sql = """
    BEGIN
      integration_pkg.mark_message_processed(:message_id, :message_hash, :processed_by);
    END;
    """

    params = [message_id: message_id, message_hash: message_hash, processed_by: processed_by]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Start aggregation via INTEGRATION_PKG.start_aggregation.
  """
  @spec start_aggregation(String.t(), String.t(), non_neg_integer(), non_neg_integer()) ::
          {:ok, pos_integer()} | {:error, term()}
  def start_aggregation(correlation_id, aggregation_type, expected_count, timeout_minutes) do
    sql = """
    DECLARE
      v_id NUMBER;
    BEGIN
      v_id := integration_pkg.start_aggregation(
        :correlation_id, :aggregation_type, :expected_count, :timeout_minutes
      );
      :out := v_id;
    END;
    """

    params = [
      correlation_id: correlation_id,
      aggregation_type: aggregation_type,
      expected_count: expected_count,
      timeout_minutes: timeout_minutes,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: id}} -> {:ok, id}
      {:ok, [id]} -> {:ok, id}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Add message to aggregation via INTEGRATION_PKG.add_to_aggregation.
  """
  @spec add_to_aggregation(pos_integer(), String.t()) :: {:ok, boolean()} | {:error, term()}
  def add_to_aggregation(aggregation_id, message_payload) do
    payload = if is_map(message_payload), do: Jason.encode!(message_payload), else: message_payload

    sql = """
    DECLARE
      v_complete NUMBER;
    BEGIN
      v_complete := integration_pkg.add_to_aggregation(:aggregation_id, :payload);
      :out := v_complete;
    END;
    """

    params = [
      aggregation_id: aggregation_id,
      payload: payload,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: 1}} -> {:ok, true}
      {:ok, %{out: 0}} -> {:ok, false}
      {:ok, [1]} -> {:ok, true}
      {:ok, [0]} -> {:ok, false}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Complete aggregation and get combined result via INTEGRATION_PKG.complete_aggregation.
  """
  @spec complete_aggregation(pos_integer()) :: {:ok, term()} | {:error, term()}
  def complete_aggregation(aggregation_id) do
    sql = """
    DECLARE
      v_result CLOB;
    BEGIN
      v_result := integration_pkg.complete_aggregation(:aggregation_id);
      :out := v_result;
    END;
    """

    params = [aggregation_id: aggregation_id, out: {:out, :string}]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: result}} ->
        {:ok, Jason.decode!(result)}

      {:ok, [result]} ->
        {:ok, Jason.decode!(result)}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Retry a failed message via INTEGRATION_PKG.retry_message.
  """
  @spec retry_message(pos_integer()) :: {:ok, DateTime.t()} | {:error, :max_retries | term()}
  def retry_message(message_id) do
    sql = """
    DECLARE
      v_next_retry TIMESTAMP;
    BEGIN
      v_next_retry := integration_pkg.retry_message(:message_id);
      :out := TO_CHAR(v_next_retry, 'YYYY-MM-DD"T"HH24:MI:SS');
    END;
    """

    params = [message_id: message_id, out: {:out, :string}]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: nil}} ->
        {:error, :max_retries}

      {:ok, %{out: next_retry}} ->
        {:ok, DateTime.from_iso8601!(next_retry <> "Z")}

      {:ok, [nil]} ->
        {:error, :max_retries}

      {:ok, [next_retry]} ->
        {:ok, DateTime.from_iso8601!(next_retry <> "Z")}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Move message to dead letter queue via INTEGRATION_PKG.move_to_dead_letter.
  """
  @spec move_to_dead_letter(pos_integer(), String.t()) :: :ok | {:error, term()}
  def move_to_dead_letter(message_id, reason) do
    sql = """
    BEGIN
      integration_pkg.move_to_dead_letter(:message_id, :reason);
    END;
    """

    params = [message_id: message_id, reason: reason]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Log a message to the integration_messages table.
  """
  @spec log_message(Message.t(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def log_message(%Message{} = message, status) do
    sql = """
    INSERT INTO integration_messages (
      message_id, correlation_id, message_type, source_system,
      destination, routing_key, payload, format, priority, status, created_at
    ) VALUES (
      :message_id, :correlation_id, :message_type, :source_system,
      :destination, :routing_key, :payload, 'JSON', :priority, :status, SYSTIMESTAMP
    ) RETURNING id INTO :out
    """

    params = [
      message_id: message.id,
      correlation_id: message.correlation_id,
      message_type: message.message_type,
      source_system: message.source_system,
      destination: message.routing_key,
      routing_key: message.routing_key,
      payload: Jason.encode!(message.payload),
      priority: message.priority,
      status: status,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: id}} -> {:ok, id}
      {:ok, [id]} -> {:ok, id}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Get routing rules from database.
  """
  @spec get_routing_rules(String.t() | nil) :: {:ok, [map()]} | {:error, term()}
  def get_routing_rules(tenant_id \\ nil) do
    {sql, params} =
      if tenant_id do
        {"SELECT * FROM routing_rules WHERE (tenant_id = :1 OR tenant_id IS NULL) AND active = 1 ORDER BY priority",
         [tenant_id]}
      else
        {"SELECT * FROM routing_rules WHERE active = 1 ORDER BY priority", []}
      end

    case OracleConnection.query(:gprint_pool, sql, params) do
      {:ok, rows} ->
        rules = Enum.map(rows, fn row ->
          %{
            rule_name: row[:rule_name],
            message_type_pattern: row[:message_type_pattern],
            routing_key_pattern: row[:routing_key_pattern],
            condition_json: row[:condition_json] && Jason.decode!(row[:condition_json]),
            destination: row[:destination],
            priority: row[:priority]
          }
        end)
        {:ok, rules}

      {:error, error} ->
        {:error, error}
    end
  end
end
