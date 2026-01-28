defmodule GprintEx.Integration.Routers.RoutingDSL do
  @moduledoc """
  Domain-Specific Language for defining message routing rules.

  Provides a declarative syntax for building routing configurations
  that can be used with ContentBasedRouter and DynamicRouter.

  ## Example

      import GprintEx.Integration.Routers.RoutingDSL

      routes = [
        when_type("CONTRACT_CREATE", route_to: :contracts),
        when_type("CUSTOMER_*", route_to: :customers),
        when_field(:priority, equals: "HIGH", route_to: :priority_queue),
        otherwise(route_to: :unrouted)
      ]

      # Finalize and use with ContentBasedRouter
      finalized = finalize_routes(routes)
  """

  @type route_spec :: %{
          condition: term(),
          destination: atom(),
          priority: non_neg_integer(),
          transform: (term() -> term()) | nil
        }

  @doc """
  Define a routing table using the DSL.
  """
  defmacro routing(do: block) do
    quote do
      import GprintEx.Integration.Routers.RoutingDSL

      routes = unquote(block)
      GprintEx.Integration.Routers.RoutingDSL.finalize_routes(routes)
    end
  end

  @doc """
  Build routes from a list of specifications.
  """
  @spec build(keyword() | [map()]) :: [route_spec()]
  def build(specs) when is_list(specs) do
    specs
    |> Enum.with_index()
    |> Enum.map(&build_route_spec/1)
  end

  @doc """
  Build routes from a declarative map structure.
  """
  @spec from_map(map()) :: [route_spec()]
  def from_map(%{routes: routes}) when is_list(routes) do
    routes
    |> Enum.with_index()
    |> Enum.map(fn {route_def, idx} ->
      %{
        condition: parse_condition(route_def[:when]),
        destination: route_def[:destination],
        priority: route_def[:priority] || idx,
        transform: nil
      }
    end)
  end

  @doc """
  Define a route for a specific message type.
  """
  @spec when_type(String.t(), keyword()) :: route_spec()
  def when_type(type_pattern, opts) when is_binary(type_pattern) do
    destination = Keyword.fetch!(opts, :route_to)

    condition =
      if String.contains?(type_pattern, "*") do
        # Escape regex metacharacters first, then replace escaped "\*" with ".*"
        escaped = Regex.escape(type_pattern) |> String.replace("\\*", ".*")
        regex = Regex.compile!("^" <> escaped <> "$")
        {:field_matches, :message_type, regex}
      else
        {:field_equals, :message_type, type_pattern}
      end

    %{
      condition: condition,
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Define a route based on a field condition.
  """
  @spec when_field(atom() | String.t(), keyword()) :: route_spec()
  def when_field(field, opts) do
    destination = Keyword.fetch!(opts, :route_to)
    condition = build_field_condition(field, opts)

    %{
      condition: condition,
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Define a route based on a routing key pattern.
  """
  @spec when_routing_key(String.t() | Regex.t(), keyword()) :: route_spec()
  def when_routing_key(pattern, opts) do
    destination = Keyword.fetch!(opts, :route_to)

    condition =
      case pattern do
        %Regex{} = r -> {:field_matches, :routing_key, r}
        p when is_binary(p) -> {:field_equals, :routing_key, p}
      end

    %{
      condition: condition,
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Define a route for header matching.
  """
  @spec when_header(String.t(), keyword()) :: route_spec()
  def when_header(header_name, opts) do
    destination = Keyword.fetch!(opts, :route_to)
    expected = Keyword.get(opts, :equals)
    exists = Keyword.get(opts, :exists, false)

    condition =
      cond do
        expected != nil -> {:header_equals, header_name, expected}
        exists -> {:header_exists, header_name}
        true -> raise ArgumentError, "must specify :equals or :exists for when_header"
      end

    %{
      condition: condition,
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Define a default/fallback route.
  """
  @spec otherwise(keyword()) :: route_spec()
  def otherwise(opts) do
    destination = Keyword.fetch!(opts, :route_to)

    %{
      condition: :default,
      destination: destination,
      priority: Keyword.get(opts, :priority, 999),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Combine multiple conditions with AND.
  """
  @spec all_of([term()], keyword()) :: route_spec()
  def all_of(conditions, opts) when is_list(conditions) do
    destination = Keyword.fetch!(opts, :route_to)

    %{
      condition: {:and, conditions},
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Combine multiple conditions with OR.
  """
  @spec any_of([term()], keyword()) :: route_spec()
  def any_of(conditions, opts) when is_list(conditions) do
    destination = Keyword.fetch!(opts, :route_to)

    %{
      condition: {:or, conditions},
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Negate a condition.
  """
  @spec not_matching(term(), keyword()) :: route_spec()
  def not_matching(condition, opts) do
    destination = Keyword.fetch!(opts, :route_to)

    %{
      condition: {:not, condition},
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Define a route with a custom predicate.
  """
  @spec when_custom((term() -> boolean()), keyword()) :: route_spec()
  def when_custom(predicate, opts) when is_function(predicate, 1) do
    destination = Keyword.fetch!(opts, :route_to)

    %{
      condition: {:custom, predicate},
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      transform: Keyword.get(opts, :transform)
    }
  end

  @doc """
  Finalize a list of route specs, sorting by priority.
  """
  @spec finalize_routes([route_spec()]) :: [route_spec()]
  def finalize_routes(routes) when is_list(routes) do
    routes
    |> List.flatten()
    |> Enum.sort_by(& &1.priority)
  end

  @doc """
  Convert routes to a format usable by ContentBasedRouter.
  """
  @spec to_content_router_rules([route_spec()]) :: [map()]
  def to_content_router_rules(routes) do
    Enum.map(routes, fn route ->
      %{
        condition: route.condition,
        destination: route.destination,
        priority: route.priority,
        transform: route.transform
      }
    end)
  end

  @doc """
  Validate routing rules.
  """
  @spec validate([route_spec()]) :: {:ok, [route_spec()]} | {:error, [String.t()]}
  def validate(routes) do
    errors =
      routes
      |> Enum.with_index()
      |> Enum.flat_map(fn {route, idx} ->
        validate_route(route, idx)
      end)

    case errors do
      [] -> {:ok, routes}
      _ -> {:error, errors}
    end
  end

  # Private functions

  defp build_route_spec({{dest, condition}, idx}) do
    %{
      condition: normalize_condition(condition),
      destination: dest,
      priority: idx,
      transform: nil
    }
  end

  defp build_route_spec({%{} = spec, idx}) do
    %{
      condition: spec[:condition],
      destination: spec[:destination],
      priority: spec[:priority] || idx,
      transform: spec[:transform]
    }
  end

  defp build_field_condition(field, opts) do
    cond do
      Keyword.has_key?(opts, :equals) ->
        {:field_equals, field, opts[:equals]}

      Keyword.has_key?(opts, :matches) ->
        {:field_matches, field, opts[:matches]}

      Keyword.has_key?(opts, :in) ->
        {:field_in, field, opts[:in]}

      Keyword.has_key?(opts, :exists) and opts[:exists] ->
        {:field_exists, field}

      true ->
        raise ArgumentError, "must specify :equals, :matches, :in, or :exists for when_field"
    end
  end

  defp parse_condition(nil), do: :default

  defp parse_condition(%{type: type}) do
    {:field_equals, :message_type, type}
  end

  defp parse_condition(%{type_pattern: pattern}) do
    # Escape regex metacharacters first, then replace escaped "\*" with ".*"
    escaped = Regex.escape(pattern) |> String.replace("\\*", ".*")
    regex = Regex.compile!("^" <> escaped <> "$")
    {:field_matches, :message_type, regex}
  end

  defp parse_condition(%{field: field, equals: value}) do
    {:field_equals, field, value}
  end

  defp parse_condition(%{field: field, in: values}) do
    {:field_in, field, values}
  end

  defp parse_condition(:default), do: :default

  defp parse_condition(condition) do
    raise ArgumentError, "Unknown condition format: #{inspect(condition)}"
  end

  defp normalize_condition({:eq, field, value}), do: {:field_equals, field, value}
  defp normalize_condition({:match, field, regex}), do: {:field_matches, field, regex}
  defp normalize_condition({:exists, field}), do: {:field_exists, field}
  defp normalize_condition({:in, field, values}), do: {:field_in, field, values}
  defp normalize_condition(:default), do: :default
  defp normalize_condition(condition), do: condition

  defp validate_route(route, idx) do
    errors = []

    errors =
      if is_nil(route.destination) do
        ["Route #{idx}: missing destination" | errors]
      else
        errors
      end

    errors =
      if is_nil(route.condition) do
        ["Route #{idx}: missing condition" | errors]
      else
        errors
      end

    errors
  end
end
