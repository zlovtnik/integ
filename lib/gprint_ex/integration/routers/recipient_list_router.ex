defmodule GprintEx.Integration.Routers.RecipientListRouter do
  @moduledoc """
  Recipient List Router EIP pattern implementation.

  Routes a single message to multiple destinations based on a recipient list.
  The list can be static, dynamic (based on message content), or computed.

  ## Features
  - Static recipient lists
  - Dynamic lists based on message content
  - Parallel delivery to all recipients
  - Tracking of delivery results

  ## Example

      # Static list
      {:ok, results} = RecipientListRouter.route(message, [:contracts, :audit, :notifications])

      # Dynamic list from message
      {:ok, results} = RecipientListRouter.route_dynamic(message, &get_recipients/1)
  """

  require Logger

  alias GprintEx.Integration.Message
  alias GprintEx.Integration.Channels.{ChannelRegistry, MessageChannel}

  @type recipient :: atom() | pid() | {module(), atom()}
  @type delivery_result :: {:ok, recipient()} | {:error, recipient(), term()}

  @doc """
  Route a message to a static list of recipients.
  """
  @spec route(Message.t(), [recipient()]) :: {:ok, [delivery_result()]}
  def route(%Message{} = message, recipients) when is_list(recipients) do
    results =
      recipients
      |> Enum.map(&deliver_to_recipient(message, &1))

    log_delivery_results(message, results)
    {:ok, results}
  end

  @doc """
  Route a message using a dynamic recipient function.

  The function receives the message and returns a list of recipients.
  """
  @spec route_dynamic(Message.t(), (Message.t() -> [recipient()])) :: {:ok, [delivery_result()]}
  def route_dynamic(%Message{} = message, recipient_fn) when is_function(recipient_fn, 1) do
    recipients = recipient_fn.(message)
    route(message, recipients)
  end

  @doc """
  Route a message to recipients specified in the message headers.

  Looks for a "recipients" header containing a list of channel names.
  """
  @spec route_from_header(Message.t(), String.t()) :: {:ok, [delivery_result()]}
  def route_from_header(%Message{} = message, header_name \\ "recipients") do
    recipients =
      message
      |> Message.get_header(header_name, [])
      |> normalize_recipients()

    route(message, recipients)
  end

  @doc """
  Route a message to recipients from message payload field.
  """
  @spec route_from_payload(Message.t(), atom() | String.t()) :: {:ok, [delivery_result()]}
  def route_from_payload(%Message{payload: payload} = message, field) when is_map(payload) do
    recipients =
      payload
      |> Map.get(field, Map.get(payload, to_string(field), []))
      |> normalize_recipients()

    route(message, recipients)
  end

  @doc """
  Route with parallel delivery using Task.async_stream.
  """
  @spec route_parallel(Message.t(), [recipient()], keyword()) :: {:ok, [delivery_result()]}
  def route_parallel(%Message{} = message, recipients, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 5_000)
    max_concurrency = Keyword.get(opts, :max_concurrency, System.schedulers_online())

    results =
      recipients
      |> Task.async_stream(
        &deliver_to_recipient(message, &1),
        max_concurrency: max_concurrency,
        timeout: timeout,
        on_timeout: :kill_task
      )
      |> Enum.zip(recipients)
      |> Enum.map(fn
        {{:ok, result}, _recipient} -> result
        {{:exit, :timeout}, recipient} -> {:error, recipient, :timeout}
        {{:exit, reason}, recipient} -> {:error, recipient, reason}
      end)

    {:ok, results}
  end

  @doc """
  Route and wait for all deliveries, failing if any fail.
  """
  @spec route_all_or_fail(Message.t(), [recipient()]) ::
          {:ok, [recipient()]} | {:error, [delivery_result()]}
  def route_all_or_fail(%Message{} = message, recipients) do
    {:ok, results} = route(message, recipients)

    failures = Enum.filter(results, fn
      {:error, _, _} -> true
      _ -> false
    end)

    case failures do
      [] ->
        successful = Enum.map(results, fn {:ok, r} -> r end)
        {:ok, successful}

      _ ->
        {:error, failures}
    end
  end

  @doc """
  Get delivery statistics for a batch of results.
  """
  @spec delivery_stats([delivery_result()]) :: map()
  def delivery_stats(results) do
    {successes, failures} =
      Enum.split_with(results, fn
        {:ok, _} -> true
        {:error, _, _} -> false
      end)

    %{
      total: length(results),
      successful: length(successes),
      failed: length(failures),
      success_rate: if(results != [], do: length(successes) / length(results) * 100, else: 0)
    }
  end

  # Private functions

  defp deliver_to_recipient(message, recipient) when is_atom(recipient) do
    case ChannelRegistry.get_or_create(recipient) do
      {:ok, channel} ->
        case MessageChannel.publish(channel, message) do
          :ok -> {:ok, recipient}
          {:error, reason} -> {:error, recipient, reason}
        end

      {:error, reason} ->
        {:error, recipient, reason}
    end
  end

  defp deliver_to_recipient(message, recipient) when is_pid(recipient) do
    case MessageChannel.publish(recipient, message) do
      :ok -> {:ok, recipient}
      {:error, reason} -> {:error, recipient, reason}
    end
  end

  defp deliver_to_recipient(message, {module, function}) do
    try do
      result = apply(module, function, [message])
      case result do
        {:error, reason} -> {:error, {module, function}, reason}
        _ -> {:ok, {module, function}}
      end
    rescue
      e -> {:error, {module, function}, e}
    end
  end

  defp normalize_recipients(recipients) when is_list(recipients) do
    Enum.reduce(recipients, [], fn item, acc ->
      case item do
        r when is_atom(r) -> [r | acc]
        r when is_binary(r) ->
          try do
            [String.to_existing_atom(r) | acc]
          rescue
            ArgumentError -> acc  # Skip invalid atom strings
          end
        r -> [r | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp normalize_recipients(_), do: []

  defp log_delivery_results(message, results) do
    stats = delivery_stats(results)

    if stats.failed > 0 do
      Logger.warning(
        "RecipientListRouter: #{stats.failed}/#{stats.total} deliveries failed for message #{message.id}"
      )
    else
      Logger.debug(
        "RecipientListRouter: #{stats.successful}/#{stats.total} deliveries succeeded for message #{message.id}"
      )
    end

    :telemetry.execute(
      [:gprint_ex, :integration, :router, :recipient_list],
      %{
        total: stats.total,
        successful: stats.successful,
        failed: stats.failed
      },
      %{message_id: message.id, message_type: message.message_type}
    )
  end
end
