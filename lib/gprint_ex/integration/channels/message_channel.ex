defmodule GprintEx.Integration.Channels.MessageChannel do
  @moduledoc """
  GenServer implementing the Message Channel EIP pattern.

  A Message Channel represents a logical pipe for message communication.
  It handles message routing, prioritization, and delivery to subscribers.

  ## Features
  - Priority-based message ordering
  - Subscriber management
  - Backpressure handling
  - Telemetry instrumentation

  ## Example

      {:ok, channel} = MessageChannel.start_link(name: :contracts_channel)
      :ok = MessageChannel.subscribe(channel, self())
      :ok = MessageChannel.publish(channel, message)
  """

  use GenServer
  require Logger

  alias GprintEx.Integration.Message
  alias GprintEx.Integration.Channels.MessageQueue

  @default_max_queue_size 10_000
  @default_timeout 5_000

  # Client API

  @type channel_name :: atom() | {:global, term()} | {:via, module(), term()}
  @type subscriber :: pid() | {module(), atom()}

  @doc """
  Start a message channel.

  ## Options
  - `:name` - Channel name for registration
  - `:max_queue_size` - Maximum messages in queue (default: 10,000)
  - `:persistence` - Enable message persistence (default: false)
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name)
    gen_opts = if name, do: [name: name], else: []
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Publish a message to the channel.
  """
  @spec publish(GenServer.server(), Message.t(), keyword()) :: :ok | {:error, term()}
  def publish(channel, %Message{} = message, opts \\ []) do
    priority = Keyword.get(opts, :priority, :normal)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    :telemetry.span(
      [:gprint_ex, :integration, :channel, :publish],
      %{channel: channel, message_type: message.message_type},
      fn ->
        result = GenServer.call(channel, {:publish, message, priority}, timeout)
        {result, %{}}
      end
    )
  end

  @doc """
  Subscribe to messages from this channel.
  """
  @spec subscribe(GenServer.server(), subscriber()) :: :ok
  def subscribe(channel, subscriber \\ self()) do
    GenServer.call(channel, {:subscribe, subscriber})
  end

  @doc """
  Unsubscribe from the channel.
  """
  @spec unsubscribe(GenServer.server(), subscriber()) :: :ok
  def unsubscribe(channel, subscriber \\ self()) do
    GenServer.call(channel, {:unsubscribe, subscriber})
  end

  @doc """
  Get current queue size.
  """
  @spec queue_size(GenServer.server()) :: non_neg_integer()
  def queue_size(channel) do
    GenServer.call(channel, :queue_size)
  end

  @doc """
  Get channel statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(channel) do
    GenServer.call(channel, :stats)
  end

  @doc """
  Drain all messages (for testing/shutdown).
  """
  @spec drain(GenServer.server()) :: [Message.t()]
  def drain(channel) do
    GenServer.call(channel, :drain)
  end

  # Server callbacks

  @impl true
  def init(opts) do
    max_queue_size = Keyword.get(opts, :max_queue_size, @default_max_queue_size)
    channel_name = Keyword.get(opts, :name, self())

    state = %{
      name: channel_name,
      queue: MessageQueue.new(),
      subscribers: MapSet.new(),
      max_queue_size: max_queue_size,
      stats: %{
        published: 0,
        delivered: 0,
        dropped: 0,
        started_at: DateTime.utc_now()
      }
    }

    Logger.info("Message channel started: #{inspect(channel_name)}")
    {:ok, state}
  end

  @impl true
  def handle_call({:publish, message, priority}, _from, state) do
    if MessageQueue.size(state.queue) >= state.max_queue_size do
      # Backpressure: reject message
      new_stats = Map.update!(state.stats, :dropped, &(&1 + 1))
      emit_backpressure_event(state.name, message)
      {:reply, {:error, :queue_full}, %{state | stats: new_stats}}
    else
      new_queue = MessageQueue.push(state.queue, message, priority)
      new_stats = Map.update!(state.stats, :published, &(&1 + 1))
      new_state = %{state | queue: new_queue, stats: new_stats}

      # Deliver to subscribers immediately if available
      new_state = deliver_messages(new_state)

      {:reply, :ok, new_state}
    end
  end

  def handle_call({:subscribe, subscriber}, _from, state) do
    ref = if is_pid(subscriber), do: Process.monitor(subscriber), else: nil
    new_subscribers = MapSet.put(state.subscribers, {subscriber, ref})
    Logger.debug("Subscriber added to channel #{inspect(state.name)}: #{inspect(subscriber)}")
    {:reply, :ok, %{state | subscribers: new_subscribers}}
  end

  def handle_call({:unsubscribe, subscriber}, _from, state) do
    # Find and remove subscriber
    {to_remove, remaining} =
      Enum.split_with(state.subscribers, fn {sub, _ref} -> sub == subscriber end)

    # Demonitor if we were monitoring
    Enum.each(to_remove, fn {_sub, ref} ->
      if ref, do: Process.demonitor(ref, [:flush])
    end)

    {:reply, :ok, %{state | subscribers: MapSet.new(remaining)}}
  end

  def handle_call(:queue_size, _from, state) do
    {:reply, MessageQueue.size(state.queue), state}
  end

  def handle_call(:stats, _from, state) do
    stats =
      state.stats
      |> Map.put(:queue_size, MessageQueue.size(state.queue))
      |> Map.put(:subscriber_count, MapSet.size(state.subscribers))

    {:reply, stats, state}
  end

  def handle_call(:drain, _from, state) do
    {messages, new_queue} = MessageQueue.drain(state.queue)
    {:reply, messages, %{state | queue: new_queue}}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    # Remove dead subscriber
    new_subscribers =
      state.subscribers
      |> Enum.reject(fn {sub, sub_ref} -> sub == pid or sub_ref == ref end)
      |> MapSet.new()

    Logger.debug("Subscriber removed from channel #{inspect(state.name)}: #{inspect(pid)}")
    {:noreply, %{state | subscribers: new_subscribers}}
  end

  def handle_info(:deliver, state) do
    {:noreply, deliver_messages(state)}
  end

  # Private functions

  defp deliver_messages(state) do
    case MessageQueue.pop(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, message}, new_queue} ->
        deliver_to_subscribers(message, state.subscribers)
        subscriber_count = MapSet.size(state.subscribers)
        new_stats = Map.update!(state.stats, :delivered, &(&1 + subscriber_count))
        # Continue delivering if queue not empty
        new_state = %{state | queue: new_queue, stats: new_stats}
        if MessageQueue.size(new_queue) > 0, do: send(self(), :deliver)
        new_state
    end
  end

  defp deliver_to_subscribers(message, subscribers) do
    Enum.each(subscribers, fn {subscriber, _ref} ->
      case subscriber do
        pid when is_pid(pid) ->
          send(pid, {:message, message})

        {module, function} ->
          spawn(fn -> apply(module, function, [message]) end)
      end
    end)
  end

  defp emit_backpressure_event(channel_name, message) do
    :telemetry.execute(
      [:gprint_ex, :integration, :channel, :backpressure],
      %{count: 1},
      %{channel: channel_name, message_type: message.message_type}
    )
  end
end
