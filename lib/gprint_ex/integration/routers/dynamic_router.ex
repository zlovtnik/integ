defmodule GprintEx.Integration.Routers.DynamicRouter do
  @moduledoc """
  Dynamic Router EIP pattern implementation.

  Routes messages based on runtime-configurable routing tables.
  Supports loading routes from database (via PL/SQL integration_pkg),
  configuration, or programmatic updates.

  ## Features
  - Runtime routing table updates
  - Database-backed routing rules
  - Routing slip support
  - Control bus integration

  ## Example

      {:ok, router} = DynamicRouter.start_link(name: :main_router)

      # Add route
      :ok = DynamicRouter.add_route(router, "CONTRACT_*", :contracts)

      # Route message
      {:ok, dest} = DynamicRouter.route(router, message)
  """

  use GenServer
  require Logger

  alias GprintEx.Integration.Message
  alias GprintEx.Integration.Channels.{ChannelRegistry, MessageChannel}

  @type route_entry :: %{
          pattern: String.t() | Regex.t(),
          destination: atom() | pid(),
          priority: non_neg_integer(),
          active: boolean(),
          metadata: map()
        }

  # Client API

  @doc """
  Start a dynamic router.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Route a message using the current routing table.
  """
  @spec route(GenServer.server(), Message.t()) :: {:ok, atom()} | {:error, :no_route}
  def route(router, %Message{} = message) do
    GenServer.call(router, {:route, message})
  end

  @doc """
  Route and deliver a message.
  """
  @spec route_and_deliver(GenServer.server(), Message.t()) ::
          {:ok, atom()} | {:error, term()}
  def route_and_deliver(router, %Message{} = message) do
    with {:ok, destination} <- route(router, message),
         {:ok, channel} <- ChannelRegistry.get_or_create(destination),
         :ok <- MessageChannel.publish(channel, message) do
      {:ok, destination}
    end
  end

  @doc """
  Add a routing entry.
  """
  @spec add_route(GenServer.server(), String.t() | Regex.t(), atom(), keyword()) :: :ok
  def add_route(router, pattern, destination, opts \\ []) do
    GenServer.call(router, {:add_route, pattern, destination, opts})
  end

  @doc """
  Remove a routing entry.
  """
  @spec remove_route(GenServer.server(), String.t() | Regex.t()) :: :ok | {:error, :not_found}
  def remove_route(router, pattern) do
    GenServer.call(router, {:remove_route, pattern})
  end

  @doc """
  Update routing table from list of entries.
  """
  @spec update_routes(GenServer.server(), [route_entry()]) :: :ok
  def update_routes(router, routes) do
    GenServer.call(router, {:update_routes, routes})
  end

  @doc """
  Get current routing table.
  """
  @spec get_routes(GenServer.server()) :: [route_entry()]
  def get_routes(router) do
    GenServer.call(router, :get_routes)
  end

  @doc """
  Enable/disable a route.
  """
  @spec set_route_active(GenServer.server(), String.t() | Regex.t(), boolean()) ::
          :ok | {:error, :not_found}
  def set_route_active(router, pattern, active) do
    GenServer.call(router, {:set_route_active, pattern, active})
  end

  @doc """
  Reload routes from database.
  """
  @spec reload_from_database(GenServer.server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reload_from_database(router) do
    GenServer.call(router, :reload_from_database)
  end

  @doc """
  Get routing statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(router) do
    GenServer.call(router, :stats)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    # Load initial routes from config or database
    initial_routes = Keyword.get(opts, :routes, [])
    load_from_db = Keyword.get(opts, :load_from_database, false)

    state = %{
      routes: [],
      stats: %{
        routed: 0,
        unrouted: 0,
        route_hits: %{}
      }
    }

    # Convert initial routes to route entries
    routes = Enum.map(initial_routes, &normalize_route_entry/1)
    state = %{state | routes: sort_routes(routes)}

    # Optionally load from database
    state =
      if load_from_db do
        case load_routes_from_db() do
          {:ok, db_routes} ->
            merged = merge_routes(state.routes, db_routes)
            %{state | routes: sort_routes(merged)}

          {:error, reason} ->
            Logger.warning("Failed to load routes from database: #{inspect(reason)}")
            state
        end
      else
        state
      end

    {:ok, state}
  end

  @impl true
  def handle_call({:route, message}, _from, state) do
    case find_route(message, state.routes) do
      {:ok, route} ->
        new_stats = update_stats(state.stats, route.destination)
        emit_routing_event(message, route.destination)
        {:reply, {:ok, route.destination}, %{state | stats: new_stats}}

      {:error, :no_route} ->
        new_stats = %{state.stats | unrouted: state.stats.unrouted + 1}
        {:reply, {:error, :no_route}, %{state | stats: new_stats}}
    end
  end

  def handle_call({:add_route, pattern, destination, opts}, _from, state) do
    entry = %{
      pattern: pattern,
      destination: destination,
      priority: Keyword.get(opts, :priority, 100),
      active: Keyword.get(opts, :active, true),
      metadata: Keyword.get(opts, :metadata, %{})
    }

    new_routes = sort_routes([entry | state.routes])
    {:reply, :ok, %{state | routes: new_routes}}
  end

  def handle_call({:remove_route, pattern}, _from, state) do
    new_routes = Enum.reject(state.routes, &(pattern_key(&1.pattern) == pattern_key(pattern)))

    if length(new_routes) == length(state.routes) do
      {:reply, {:error, :not_found}, state}
    else
      {:reply, :ok, %{state | routes: new_routes}}
    end
  end

  def handle_call({:update_routes, routes}, _from, state) do
    normalized = Enum.map(routes, &normalize_route_entry/1)
    {:reply, :ok, %{state | routes: sort_routes(normalized)}}
  end

  def handle_call(:get_routes, _from, state) do
    {:reply, state.routes, state}
  end

  def handle_call({:set_route_active, pattern, active}, _from, state) do
    target_key = pattern_key(pattern)
    {updated, remaining} =
      Enum.split_with(state.routes, &(pattern_key(&1.pattern) == target_key))

    case updated do
      [] ->
        {:reply, {:error, :not_found}, state}

      routes ->
        new_routes = Enum.map(routes, &%{&1 | active: active})
        all_routes = sort_routes(new_routes ++ remaining)
        {:reply, :ok, %{state | routes: all_routes}}
    end
  end

  def handle_call(:reload_from_database, _from, state) do
    case load_routes_from_db() do
      {:ok, db_routes} ->
        merged = merge_routes(state.routes, db_routes)
        new_state = %{state | routes: sort_routes(merged)}
        {:reply, {:ok, length(db_routes)}, new_state}

      {:error, _} = error ->
        {:reply, error, state}
    end
  end

  def handle_call(:stats, _from, state) do
    stats = Map.put(state.stats, :route_count, length(state.routes))
    {:reply, stats, state}
  end

  # Private functions

  defp find_route(message, routes) do
    routes
    |> Enum.filter(& &1.active)
    |> Enum.find_value({:error, :no_route}, fn route ->
      if matches_pattern?(message, route.pattern) do
        {:ok, route}
      else
        nil
      end
    end)
  end

  defp matches_pattern?(%Message{message_type: type}, pattern) when is_binary(pattern) do
    type == pattern
  end

  defp matches_pattern?(%Message{message_type: type}, {:glob_regex, %Regex{} = regex}) do
    Regex.match?(regex, type)
  end

  defp matches_pattern?(%Message{message_type: type}, %Regex{} = pattern) do
    Regex.match?(pattern, type)
  end

  defp matches_pattern?(%Message{} = msg, fun) when is_function(fun, 1) do
    try do
      fun.(msg)
    rescue
      e ->
        Logger.error("Custom route predicate raised exception: #{Exception.format(:error, e, __STACKTRACE__)}")
        false
    end
  end

  defp normalize_route_entry(%{pattern: pattern, destination: _} = entry) do
    normalized_pattern = precompile_pattern(pattern)
    Map.merge(
      %{priority: 100, active: true, metadata: %{}},
      %{entry | pattern: normalized_pattern}
    )
  end

  defp normalize_route_entry({pattern, destination}) do
    normalized_pattern = precompile_pattern(pattern)
    %{pattern: normalized_pattern, destination: destination, priority: 100, active: true, metadata: %{}}
  end

  defp precompile_pattern(pattern) when is_binary(pattern) do
    if String.contains?(pattern, "*") do
      # Escape regex metacharacters, then replace escaped "\*" with ".*"
      escaped = Regex.escape(pattern) |> String.replace("\\*", ".*")
      {:glob_regex, Regex.compile!("^" <> escaped <> "$")}
    else
      pattern
    end
  end

  defp precompile_pattern(pattern), do: pattern

  defp sort_routes(routes) do
    Enum.sort_by(routes, & &1.priority)
  end

  defp merge_routes(existing, new) do
    existing_keys = MapSet.new(existing, &pattern_key(&1.pattern))

    new_routes =
      Enum.reject(new, fn route ->
        MapSet.member?(existing_keys, pattern_key(route.pattern))
      end)

    existing ++ new_routes
  end

  defp pattern_key(pattern) when is_binary(pattern), do: pattern
  defp pattern_key(%Regex{source: source}), do: {:regex, source}
  defp pattern_key(fun) when is_function(fun, 1), do: {:function, :erlang.fun_info(fun, :uniq)}
  defp pattern_key(_), do: :unknown

  defp update_stats(stats, destination) do
    stats
    |> Map.update!(:routed, &(&1 + 1))
    |> Map.update!(:route_hits, fn hits ->
      Map.update(hits, destination, 1, &(&1 + 1))
    end)
  end

  defp load_routes_from_db do
    # This would call the PL/SQL integration_pkg to load routing rules
    # For now, return empty list as placeholder
    {:ok, []}
  end

  defp emit_routing_event(message, destination) do
    :telemetry.execute(
      [:gprint_ex, :integration, :router, :dynamic_routed],
      %{count: 1},
      %{
        message_type: message.message_type,
        destination: destination,
        message_id: message.id
      }
    )
  end
end
