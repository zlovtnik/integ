defmodule GprintEx.Integration.Channels.ChannelRegistry do
  @moduledoc """
  Dynamic channel management using Registry.

  Provides a central registry for message channels, allowing channels
  to be looked up by name and dynamically created/destroyed.

  ## Example

      # Start the registry (typically in application supervisor)
      {:ok, _} = ChannelRegistry.start_link()

      # Get or create a channel
      {:ok, channel} = ChannelRegistry.get_or_create(:contracts)

      # Look up existing channel
      {:ok, channel} = ChannelRegistry.lookup(:contracts)
  """

  use Supervisor
  require Logger

  alias GprintEx.Integration.Channels.MessageChannel

  @registry_name __MODULE__.Registry
  @supervisor_name __MODULE__.Supervisor

  # Client API

  @doc """
  Start the channel registry and supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Look up a channel by name.
  """
  @spec lookup(atom()) :: {:ok, pid()} | {:error, :not_found}
  def lookup(channel_name) when is_atom(channel_name) do
    case Registry.lookup(@registry_name, channel_name) do
      [{pid, _}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @doc """
  Get a channel by name, creating it if it doesn't exist.
  """
  @spec get_or_create(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def get_or_create(channel_name, opts \\ []) when is_atom(channel_name) do
    case lookup(channel_name) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, :not_found} ->
        create_channel(channel_name, opts)
    end
  end

  @doc """
  Create a new channel.
  """
  @spec create_channel(atom(), keyword()) :: {:ok, pid()} | {:error, term()}
  def create_channel(channel_name, opts \\ []) when is_atom(channel_name) do
    child_spec = {
      MessageChannel,
      Keyword.merge(opts, name: via_tuple(channel_name))
    }

    case DynamicSupervisor.start_child(@supervisor_name, child_spec) do
      {:ok, pid} ->
        Logger.info("Created channel: #{channel_name}")
        {:ok, pid}

      {:error, {:already_started, pid}} ->
        {:ok, pid}

      {:error, reason} = error ->
        Logger.error("Failed to create channel #{channel_name}: #{inspect(reason)}")
        error
    end
  end

  @doc """
  Stop and remove a channel.
  """
  @spec remove_channel(atom()) :: :ok | {:error, :not_found}
  def remove_channel(channel_name) when is_atom(channel_name) do
    case lookup(channel_name) do
      {:ok, pid} ->
        case DynamicSupervisor.terminate_child(@supervisor_name, pid) do
          :ok ->
            Logger.info("Removed channel: #{channel_name}")
            :ok

          {:error, :not_found} ->
            {:error, :not_found}
        end

      {:error, :not_found} ->
        {:error, :not_found}
    end
  end

  @doc """
  Get a channel by name (alias for lookup).
  """
  @spec get_channel(atom()) :: {:ok, pid()} | {:error, :not_found}
  def get_channel(channel_name), do: lookup(channel_name)

  @doc """
  List all registered channels.
  """
  @spec list_channels() :: {:ok, [{atom(), pid()}]}
  def list_channels do
    channels = Registry.select(@registry_name, [{{:"$1", :"$2", :_}, [], [{{:"$1", :"$2"}}]}])
    {:ok, channels}
  end

  @doc """
  Get statistics for all channels.
  """
  @spec all_stats() :: map()
  def all_stats do
    list_channels()
    |> Enum.reduce(%{}, fn {name, pid}, acc ->
      case safe_get_stats(pid) do
        {:ok, stats} -> Map.put(acc, name, stats)
        {:error, _reason} -> acc
      end
    end)
  end

  defp safe_get_stats(pid) do
    {:ok, MessageChannel.stats(pid)}
  catch
    :exit, reason -> {:error, reason}
  end

  @doc """
  Check if a channel exists.
  """
  @spec channel_exists?(atom()) :: boolean()
  def channel_exists?(channel_name) do
    case lookup(channel_name) do
      {:ok, _} -> true
      {:error, :not_found} -> false
    end
  end

  # Supervisor callbacks

  @impl true
  def init(_opts) do
    children = [
      {Registry, keys: :unique, name: @registry_name},
      {DynamicSupervisor, strategy: :one_for_one, name: @supervisor_name}
    ]

    Supervisor.init(children, strategy: :one_for_all)
  end

  # Private functions

  defp via_tuple(channel_name) do
    {:via, Registry, {@registry_name, channel_name}}
  end
end
