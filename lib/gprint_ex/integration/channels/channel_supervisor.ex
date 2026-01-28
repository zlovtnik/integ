defmodule GprintEx.Integration.Channels.ChannelSupervisor do
  @moduledoc """
  Supervisor for the EIP channel infrastructure.

  Manages the channel registry and pre-configured channels.
  Add this to your application supervision tree.

  ## Example

      # In your Application module:
      children = [
        GprintEx.Integration.Channels.ChannelSupervisor
      ]
  """

  use Supervisor
  require Logger

  alias GprintEx.Integration.Channels.ChannelRegistry

  @doc """
  Start the channel supervisor.
  """
  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    # Pre-configured channels to start on boot
    default_channels = Keyword.get(opts, :channels, [])

    children =
      [
        # Start the registry first
        ChannelRegistry
      ] ++
        if default_channels != [] do
          # Add a Task child to create default channels after registry starts
          [{Task, fn -> ensure_channels(default_channels) end}]
        else
          []
        end

    Supervisor.init(children, strategy: :one_for_one)
  end

  @doc """
  Create default channels for the application.

  Call this after the supervisor is started if you need specific channels.
  """
  @spec ensure_channels([atom()]) :: :ok
  def ensure_channels(channel_names) do
    Enum.each(channel_names, fn name ->
      case ChannelRegistry.get_or_create(name) do
        {:ok, _pid} -> :ok
        {:error, reason} -> Logger.warning("Failed to create channel #{name}: #{inspect(reason)}")
      end
    end)
  end

  @doc """
  Get standard channel names used by the application.
  """
  @spec standard_channels() :: [atom()]
  def standard_channels do
    [
      :contracts,
      :customers,
      :etl_commands,
      :etl_events,
      :integration_events,
      :dead_letter
    ]
  end
end
