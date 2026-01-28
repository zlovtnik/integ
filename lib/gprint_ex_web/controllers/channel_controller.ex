defmodule GprintExWeb.ChannelController do
  @moduledoc """
  Controller for message channel management.

  Provides visibility into EIP message channels for monitoring and debugging.
  """

  use Phoenix.Controller, formats: [:json]

  alias GprintEx.Integration.Channels.{ChannelRegistry, MessageChannel}
  alias GprintExWeb.Plugs.AuthPlug

  action_fallback GprintExWeb.FallbackController

  @doc """
  List all active channels.
  GET /api/v1/channels
  """
  def index(conn, _params) do
    _ctx = AuthPlug.tenant_context(conn)

    with {:ok, channels} <- ChannelRegistry.list_channels() do
      channel_data = Enum.map(channels, fn {name, pid} ->
        stats = MessageChannel.stats(pid)
        %{
          name: name,
          pid: inspect(pid),
          queue_size: stats.queue_size || 0,
          published: stats.published || 0,
          delivered: stats.delivered || 0,
          dropped: stats.dropped || 0,
          started_at: stats.started_at
        }
      end)

      json(conn, %{success: true, data: channel_data})
    end
  end

  @doc """
  Get channel statistics.
  GET /api/v1/channels/:name
  """
  def show(conn, %{"name" => channel_name}) do
    _ctx = AuthPlug.tenant_context(conn)
    name = String.to_existing_atom(channel_name)

    case ChannelRegistry.get_channel(name) do
      {:ok, pid} ->
        stats = MessageChannel.stats(pid)
        json(conn, %{success: true, data: %{
          name: name,
          pid: inspect(pid),
          stats: stats
        }})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  @doc """
  Create/get a channel.
  POST /api/v1/channels
  """
  def create(conn, %{"name" => channel_name}) do
    _ctx = AuthPlug.tenant_context(conn)
    name = String.to_atom(channel_name)

    with {:ok, pid} <- ChannelRegistry.get_or_create(name) do
      conn
      |> put_status(:created)
      |> json(%{success: true, data: %{
        name: name,
        pid: inspect(pid),
        message: "Channel ready"
      }})
    end
  end

  @doc """
  Drain a channel (for debugging/testing).
  POST /api/v1/channels/:name/drain
  """
  def drain(conn, %{"name" => channel_name}) do
    _ctx = AuthPlug.tenant_context(conn)
    name = String.to_existing_atom(channel_name)

    case ChannelRegistry.get_channel(name) do
      {:ok, pid} ->
        messages = MessageChannel.drain(pid)
        json(conn, %{success: true, data: %{
          drained_count: length(messages),
          messages: Enum.map(messages, &message_to_response/1)
        }})

      {:error, :not_found} ->
        {:error, :not_found}
    end
  rescue
    ArgumentError -> {:error, :not_found}
  end

  defp message_to_response(message) do
    %{
      id: message.id,
      message_type: message.message_type,
      source_system: message.source_system,
      routing_key: message.routing_key,
      priority: GprintEx.Integration.Message.get_header(message, "priority", 5),
      created_at: message.created_at
    }
  end
end
