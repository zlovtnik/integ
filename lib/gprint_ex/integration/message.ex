defmodule GprintEx.Integration.Message do
  @moduledoc """
  Core message structure for EIP patterns.

  Messages are the fundamental unit of communication in the integration layer.
  Each message has a unique ID, type, payload, and metadata for routing/tracking.
  """

  alias GprintEx.Result

  @type t :: %__MODULE__{
          id: String.t(),
          correlation_id: String.t() | nil,
          message_type: String.t(),
          payload: map() | binary(),
          routing_key: String.t() | nil,
          source_system: String.t() | nil,
          headers: map(),
          created_at: DateTime.t() | nil,
          retry_count: non_neg_integer()
        }

  @enforce_keys [:id, :message_type, :payload]
  defstruct [
    :id,
    :correlation_id,
    :message_type,
    :payload,
    :routing_key,
    :source_system,
    headers: %{},
    created_at: nil,
    retry_count: 0
  ]

  @doc """
  Create a new message with auto-generated ID.
  """
  @spec new(String.t(), map() | binary(), keyword()) :: {:ok, t()} | {:error, term()}
  def new(message_type, payload, opts \\ []) when is_binary(message_type) do
    message = %__MODULE__{
      id: Keyword.get(opts, :id, generate_id()),
      correlation_id: Keyword.get(opts, :correlation_id),
      message_type: message_type,
      payload: payload,
      routing_key: Keyword.get(opts, :routing_key),
      source_system: Keyword.get(opts, :source_system),
      headers: Keyword.get(opts, :headers, %{}),
      created_at: DateTime.utc_now(),
      retry_count: 0
    }

    {:ok, message}
  end

  @doc """
  Create a new message, raising on failure.
  """
  @spec new!(String.t(), map() | binary(), keyword()) :: t()
  def new!(message_type, payload, opts \\ []) do
    {:ok, message} = new(message_type, payload, opts)
    message
  end

  @doc """
  Build message from database row.
  """
  @spec from_row(map()) :: {:ok, t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    {:ok,
     %__MODULE__{
       id: row[:id] || row["id"] || row[:message_id] || row["message_id"],
       correlation_id: row[:correlation_id] || row["correlation_id"],
       message_type: row[:message_type] || row["message_type"],
       payload: parse_payload(row[:payload] || row["payload"]),
       routing_key: row[:routing_key] || row["routing_key"],
       source_system: row[:source_system] || row["source_system"],
       headers: parse_headers(row[:headers] || row["headers"]),
       created_at: row[:created_at] || row["created_at"],
       retry_count: row[:retry_count] || row["retry_count"] || 0
     }}
  end

  @doc """
  Convert message to JSON-safe map.
  """
  @spec to_map(t()) :: map()
  def to_map(%__MODULE__{} = message) do
    %{
      id: message.id,
      correlation_id: message.correlation_id,
      message_type: message.message_type,
      payload: message.payload,
      routing_key: message.routing_key,
      source_system: message.source_system,
      headers: message.headers,
      created_at: format_datetime(message.created_at),
      retry_count: message.retry_count
    }
  end

  @doc """
  Encode message payload to JSON.
  """
  @spec encode(t()) :: {:ok, binary()} | {:error, term()}
  def encode(%__MODULE__{} = message) do
    Result.try_apply(fn -> Jason.encode!(to_map(message)) end)
  end

  @doc """
  Decode message from JSON.
  """
  @spec decode(binary()) :: {:ok, t()} | {:error, term()}
  def decode(json) when is_binary(json) do
    with {:ok, data} <- Jason.decode(json),
         {:ok, message} <- from_row(data) do
      {:ok, message}
    end
  end

  @doc """
  Set a header on the message.
  """
  @spec put_header(t(), String.t(), term()) :: t()
  def put_header(%__MODULE__{} = message, key, value) do
    %{message | headers: Map.put(message.headers, key, value)}
  end

  @doc """
  Get a header from the message.
  """
  @spec get_header(t(), String.t(), term()) :: term()
  def get_header(%__MODULE__{headers: headers}, key, default \\ nil) do
    Map.get(headers, key, default)
  end

  @doc """
  Increment retry count.
  """
  @spec increment_retry(t()) :: t()
  def increment_retry(%__MODULE__{retry_count: count} = message) do
    %{message | retry_count: count + 1}
  end

  @doc """
  Check if message has exceeded max retries.
  """
  @spec max_retries_exceeded?(t(), non_neg_integer()) :: boolean()
  def max_retries_exceeded?(%__MODULE__{retry_count: count}, max_retries) do
    count >= max_retries
  end

  @doc """
  Generate a correlation ID for linking related messages.
  """
  @spec generate_correlation_id() :: String.t()
  def generate_correlation_id, do: generate_id()

  @doc """
  Create a child message with same correlation ID.
  """
  @spec create_child(t(), String.t(), map(), keyword()) :: {:ok, t()} | {:error, term()}
  def create_child(%__MODULE__{correlation_id: parent_corr_id}, message_type, payload, opts \\ []) do
    correlation_id = parent_corr_id || generate_id()
    new(message_type, payload, Keyword.put(opts, :correlation_id, correlation_id))
  end

  # Private functions

  defp generate_id do
    :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  end

  defp parse_payload(nil), do: %{}
  defp parse_payload(payload) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> decoded
      {:error, _} -> payload
    end
  end
  defp parse_payload(payload) when is_map(payload), do: payload

  defp parse_headers(nil), do: %{}
  defp parse_headers(headers) when is_binary(headers) do
    case Jason.decode(headers) do
      {:ok, decoded} -> decoded
      {:error, _} -> %{}
    end
  end
  defp parse_headers(headers) when is_map(headers), do: headers

  defp format_datetime(nil), do: nil
  defp format_datetime(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_datetime(other), do: other
end
