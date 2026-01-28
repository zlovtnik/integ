defmodule GprintEx.Integration.Routers.ContentBasedRouter do
  @moduledoc """
  Content-Based Router EIP pattern implementation.

  Routes messages to different channels based on message content.
  Evaluates routing rules against message payload to determine destination.

  ## Features
  - Rule-based routing decisions
  - Support for field matching, pattern matching, and custom predicates
  - Integration with PL/SQL routing rules
  - Default route fallback

  ## Example

      rules = [
        %{condition: {:field_equals, :message_type, "CONTRACT_CREATE"}, destination: :contracts},
        %{condition: {:field_equals, :message_type, "CUSTOMER_CREATE"}, destination: :customers},
        %{condition: :default, destination: :unrouted}
      ]

      {:ok, destination} = ContentBasedRouter.route(message, rules)
  """

  require Logger

  alias GprintEx.Integration.Message
  alias GprintEx.Integration.Channels.{ChannelRegistry, MessageChannel}

  @type condition ::
          {:field_equals, atom() | String.t(), term()}
          | {:field_matches, atom() | String.t(), Regex.t()}
          | {:field_exists, atom() | String.t()}
          | {:field_in, atom() | String.t(), [term()]}
          | {:custom, (Message.t() -> boolean())}
          | :default

  @type route_rule :: %{
          condition: condition(),
          destination: atom() | pid() | {module(), atom()},
          priority: non_neg_integer(),
          transform: (Message.t() -> Message.t()) | nil
        }

  @doc """
  Route a message based on content.

  Evaluates rules in priority order and returns first matching destination.
  """
  @spec route(Message.t(), [route_rule()]) :: {:ok, atom()} | {:error, :no_route}
  def route(%Message{} = message, rules) when is_list(rules) do
    rules
    |> Enum.sort_by(& &1[:priority] || 100)
    |> find_matching_route(message)
  end

  @doc """
  Route a message and deliver it to the destination channel.
  """
  @spec route_and_deliver(Message.t(), [route_rule()]) ::
          {:ok, atom()} | {:error, :no_route | :delivery_failed}
  def route_and_deliver(%Message{} = message, rules) do
    with {:ok, destination} <- route(message, rules),
         {:ok, channel} <- get_channel(destination),
         :ok <- MessageChannel.publish(channel, message) do
      emit_routing_event(message, destination)
      {:ok, destination}
    else
      {:error, :no_route} = error ->
        emit_routing_failure(message, :no_route)
        error

      {:error, :not_found} ->
        emit_routing_failure(message, :channel_not_found)
        {:error, :delivery_failed}

      {:error, reason} = error ->
        emit_routing_failure(message, reason)
        error
    end
  end

  @doc """
  Route a message to multiple destinations based on all matching rules.
  """
  @spec multicast(Message.t(), [route_rule()]) :: {:ok, [atom()]} | {:error, :no_route}
  def multicast(%Message{} = message, rules) do
    destinations =
      rules
      |> Enum.filter(&matches_condition?(&1.condition, message))
      |> Enum.map(& &1.destination)

    case destinations do
      [] -> {:error, :no_route}
      dests -> {:ok, Enum.uniq(dests)}
    end
  end

  @doc """
  Route and deliver to all matching destinations.
  """
  @spec multicast_and_deliver(Message.t(), [route_rule()]) ::
          {:ok, [atom()]} | {:error, :no_route}
  def multicast_and_deliver(%Message{} = message, rules) do
    with {:ok, destinations} <- multicast(message, rules) do
      {delivered, failed} =
        destinations
        |> Enum.map(fn dest ->
          case get_channel(dest) do
            {:ok, channel} ->
              case MessageChannel.publish(channel, message) do
                :ok -> {:ok, dest}
                {:error, reason} -> {:error, dest, reason}
              end
            {:error, _} -> {:error, dest, :channel_not_found}
          end
        end)
        |> Enum.split_with(fn
          {:ok, _} -> true
          {:error, _, _} -> false
        end)

      delivered_dests = Enum.map(delivered, fn {:ok, d} -> d end)
      failed_dests = Enum.map(failed, fn {:error, d, r} -> {d, r} end)

      Logger.debug("Multicast delivered to #{length(delivered)}/#{length(destinations)} destinations")

      cond do
        failed == [] -> {:ok, delivered_dests}
        delivered == [] -> {:error, failed_dests}
        true -> {:ok, delivered_dests, failed_dests}
      end
    end
  end

  @doc """
  Evaluate a single condition against a message.
  """
  @spec matches_condition?(condition(), Message.t()) :: boolean()
  def matches_condition?(:default, _message), do: true

  def matches_condition?({:field_equals, field, expected}, %Message{} = message) do
    actual = get_field_value(message, field)
    actual == expected
  end

  def matches_condition?({:field_matches, field, regex}, %Message{} = message) do
    case get_field_value(message, field) do
      value when is_binary(value) -> Regex.match?(regex, value)
      _ -> false
    end
  end

  def matches_condition?({:field_exists, field}, %Message{} = message) do
    get_field_value(message, field) != nil
  end

  def matches_condition?({:field_in, field, values}, %Message{} = message) when is_list(values) do
    get_field_value(message, field) in values
  end

  def matches_condition?({:custom, fun}, %Message{} = message) when is_function(fun, 1) do
    try do
      fun.(message)
    rescue
      e ->
        Logger.error("Custom predicate raised exception for message #{message.id}: #{Exception.format(:error, e, __STACKTRACE__)}")
        false
    end
  end

  def matches_condition?({:and, conditions}, %Message{} = message) when is_list(conditions) do
    Enum.all?(conditions, &matches_condition?(&1, message))
  end

  def matches_condition?({:or, conditions}, %Message{} = message) when is_list(conditions) do
    Enum.any?(conditions, &matches_condition?(&1, message))
  end

  def matches_condition?({:not, condition}, %Message{} = message) do
    not matches_condition?(condition, message)
  end

  @doc """
  Build routing rules from a keyword list.
  """
  @spec build_rules(keyword()) :: [route_rule()]
  def build_rules(rules_config) when is_list(rules_config) do
    rules_config
    |> Enum.with_index()
    |> Enum.map(fn {{destination, condition}, index} ->
      %{
        condition: normalize_condition(condition),
        destination: destination,
        priority: index,
        transform: nil
      }
    end)
  end

  # Private functions

  defp find_matching_route([], _message), do: {:error, :no_route}

  defp find_matching_route([rule | rest], message) do
    if matches_condition?(rule.condition, message) do
      {:ok, rule.destination}
    else
      find_matching_route(rest, message)
    end
  end

  defp get_field_value(%Message{} = message, field) when is_atom(field) do
    case field do
      :message_type -> message.message_type
      :routing_key -> message.routing_key
      :source_system -> message.source_system
      :correlation_id -> message.correlation_id
      _ -> get_in_payload(message.payload, field)
    end
  end

  defp get_field_value(%Message{} = message, field) when is_binary(field) do
    get_in_payload(message.payload, field)
  end

  defp get_in_payload(payload, field) when is_map(payload) do
    cond do
      Map.has_key?(payload, field) -> Map.get(payload, field)
      Map.has_key?(payload, to_string(field)) -> Map.get(payload, to_string(field))
      true -> nil
    end
  end

  defp get_in_payload(_, _), do: nil

  defp normalize_condition({:eq, field, value}), do: {:field_equals, field, value}
  defp normalize_condition({:match, field, regex}), do: {:field_matches, field, regex}
  defp normalize_condition({:exists, field}), do: {:field_exists, field}
  defp normalize_condition({:in, field, values}), do: {:field_in, field, values}
  defp normalize_condition(:default), do: :default
  defp normalize_condition(condition), do: condition

  defp get_channel(destination) when is_atom(destination) do
    ChannelRegistry.get_or_create(destination)
  end

  defp get_channel(pid) when is_pid(pid), do: {:ok, pid}
  defp get_channel({_mod, _fun} = mf), do: {:ok, mf}

  defp emit_routing_event(message, destination) do
    :telemetry.execute(
      [:gprint_ex, :integration, :router, :routed],
      %{count: 1},
      %{
        message_type: message.message_type,
        destination: destination,
        message_id: message.id
      }
    )
  end

  defp emit_routing_failure(message, reason) do
    :telemetry.execute(
      [:gprint_ex, :integration, :router, :failed],
      %{count: 1},
      %{
        message_type: message.message_type,
        reason: reason,
        message_id: message.id
      }
    )
  end
end
