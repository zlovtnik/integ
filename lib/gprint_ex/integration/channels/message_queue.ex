defmodule GprintEx.Integration.Channels.MessageQueue do
  @moduledoc """
  Priority queue implementation for message channels.
  
  Messages are ordered by priority (high > normal > low) and within
  each priority by insertion order (FIFO).
  
  Implemented using three :queue structures for O(1) push/pop operations.
  """

  @type priority :: :high | :normal | :low
  @type t :: %__MODULE__{
          high: :queue.queue(),
          normal: :queue.queue(),
          low: :queue.queue(),
          size: non_neg_integer()
        }

  defstruct high: :queue.new(),
            normal: :queue.new(),
            low: :queue.new(),
            size: 0

  @doc """
  Create a new empty priority queue.
  """
  @spec new() :: t()
  def new do
    %__MODULE__{}
  end

  @doc """
  Push a message onto the queue with given priority.
  """
  @spec push(t(), term(), priority()) :: t()
  def push(%__MODULE__{} = queue, message, priority \\ :normal) do
    case priority do
      :high ->
        %{queue | high: :queue.in(message, queue.high), size: queue.size + 1}

      :normal ->
        %{queue | normal: :queue.in(message, queue.normal), size: queue.size + 1}

      :low ->
        %{queue | low: :queue.in(message, queue.low), size: queue.size + 1}
    end
  end

  @doc """
  Pop the highest priority message from the queue.
  Returns `{{:value, message}, new_queue}` or `{:empty, queue}`.
  """
  @spec pop(t()) :: {{:value, term()}, t()} | {:empty, t()}
  def pop(%__MODULE__{size: 0} = queue), do: {:empty, queue}

  def pop(%__MODULE__{high: high} = queue) do
    case :queue.out(high) do
      {{:value, message}, new_high} ->
        {{:value, message}, %{queue | high: new_high, size: queue.size - 1}}

      {:empty, _} ->
        pop_normal(queue)
    end
  end

  defp pop_normal(%__MODULE__{normal: normal} = queue) do
    case :queue.out(normal) do
      {{:value, message}, new_normal} ->
        {{:value, message}, %{queue | normal: new_normal, size: queue.size - 1}}

      {:empty, _} ->
        pop_low(queue)
    end
  end

  defp pop_low(%__MODULE__{low: low} = queue) do
    case :queue.out(low) do
      {{:value, message}, new_low} ->
        {{:value, message}, %{queue | low: new_low, size: queue.size - 1}}

      {:empty, _} ->
        {:empty, queue}
    end
  end

  @doc """
  Peek at the next message without removing it.
  """
  @spec peek(t()) :: {:value, term()} | :empty
  def peek(%__MODULE__{size: 0}), do: :empty

  def peek(%__MODULE__{high: high, normal: normal, low: low}) do
    case :queue.peek(high) do
      {:value, _} = result ->
        result

      :empty ->
        case :queue.peek(normal) do
          {:value, _} = result -> result
          :empty -> :queue.peek(low)
        end
    end
  end

  @doc """
  Get the current size of the queue.
  """
  @spec size(t()) :: non_neg_integer()
  def size(%__MODULE__{size: size}), do: size

  @doc """
  Check if the queue is empty.
  """
  @spec empty?(t()) :: boolean()
  def empty?(%__MODULE__{size: 0}), do: true
  def empty?(%__MODULE__{}), do: false

  @doc """
  Drain all messages from the queue.
  """
  @spec drain(t()) :: {[term()], t()}
  def drain(%__MODULE__{} = queue) do
    drain_acc(queue, [])
  end

  defp drain_acc(queue, acc) do
    case pop(queue) do
      {:empty, new_queue} ->
        {Enum.reverse(acc), new_queue}

      {{:value, message}, new_queue} ->
        drain_acc(new_queue, [message | acc])
    end
  end

  @doc """
  Get messages by priority level.
  """
  @spec to_list(t(), priority()) :: [term()]
  def to_list(%__MODULE__{} = queue, priority) do
    q =
      case priority do
        :high -> queue.high
        :normal -> queue.normal
        :low -> queue.low
      end

    :queue.to_list(q)
  end

  @doc """
  Get all messages as a list (ordered by priority then insertion).
  """
  @spec to_list(t()) :: [term()]
  def to_list(%__MODULE__{} = queue) do
    :queue.to_list(queue.high) ++
      :queue.to_list(queue.normal) ++
      :queue.to_list(queue.low)
  end

  @doc """
  Filter messages in the queue.
  """
  @spec filter(t(), (term() -> boolean())) :: t()
  def filter(%__MODULE__{} = queue, fun) do
    high = :queue.filter(fun, queue.high)
    normal = :queue.filter(fun, queue.normal)
    low = :queue.filter(fun, queue.low)

    new_size = :queue.len(high) + :queue.len(normal) + :queue.len(low)

    %__MODULE__{high: high, normal: normal, low: low, size: new_size}
  end
end
