defmodule GprintEx.Result do
  @moduledoc """
  Railway-oriented programming utilities.
  All operations return {:ok, value} | {:error, reason}.
  """

  require Logger

  @type t(a) :: {:ok, a} | {:error, term()}
  @type t :: t(any())

  @doc "Map over success value"
  @spec map(t(a), (a -> b)) :: t(b) when a: var, b: var
  def map({:ok, value}, fun), do: {:ok, fun.(value)}
  def map({:error, _} = err, _fun), do: err

  @doc "Flat map (bind) for chaining operations"
  @spec flat_map(t(a), (a -> t(b))) :: t(b) when a: var, b: var
  def flat_map({:ok, value}, fun), do: fun.(value)
  def flat_map({:error, _} = err, _fun), do: err

  @doc "Extract value or raise (logs error safely, does not expose reason in exception)"
  @spec unwrap!(t(a)) :: a when a: var
  def unwrap!({:ok, value}), do: value

  def unwrap!({:error, _reason}) do
    Logger.error("Result.unwrap! failed")
    raise "Unwrap failed"
  end

  @doc "Extract value or default"
  @spec unwrap_or(t(a), a) :: a when a: var
  def unwrap_or({:ok, value}, _default), do: value
  def unwrap_or({:error, _}, default), do: default

  @doc "Sequence a list of results"
  @spec sequence([t(a)]) :: t([a]) when a: var
  def sequence(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, _} = err, _acc -> {:halt, err}
    end)
    |> map(&Enum.reverse/1)
  end

  @doc "Traverse a list with a result-returning function (short-circuits on first error)"
  @spec traverse([a], (a -> t(b))) :: t([b]) when a: var, b: var
  def traverse(list, fun) do
    Enum.reduce_while(list, {:ok, []}, fn item, {:ok, acc} ->
      case fun.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = err -> {:halt, err}
      end
    end)
    |> map(&Enum.reverse/1)
  end

  @doc "Convert nil to error"
  @spec from_nilable(a | nil, term()) :: t(a) when a: var
  def from_nilable(nil, error), do: {:error, error}
  def from_nilable(value, _error), do: {:ok, value}

  @doc "Apply a function that might raise, catching exceptions"
  @spec try_apply((-> a)) :: t(a) when a: var
  def try_apply(fun) do
    {:ok, fun.()}
  rescue
    e -> {:error, e}
  end

  @doc "Combine two results with a function"
  @spec map2(t(a), t(b), (a, b -> c)) :: t(c) when a: var, b: var, c: var
  def map2({:ok, a}, {:ok, b}, fun), do: {:ok, fun.(a, b)}
  def map2({:error, _} = err, _, _fun), do: err
  def map2(_, {:error, _} = err, _fun), do: err

  @doc "Convert ok/error to boolean"
  @spec ok?(t(any())) :: boolean()
  def ok?({:ok, _}), do: true
  def ok?({:error, _}), do: false

  @doc "Convert ok/error to boolean"
  @spec error?(t(any())) :: boolean()
  def error?({:ok, _}), do: false
  def error?({:error, _}), do: true

  @doc "Tap into success value for side effects"
  @spec tap_ok(t(a), (a -> any())) :: t(a) when a: var
  def tap_ok({:ok, value} = result, fun) do
    fun.(value)
    result
  end

  def tap_ok({:error, _} = err, _fun), do: err

  @doc "Tap into error value for side effects"
  @spec tap_error(t(a), (term() -> any())) :: t(a) when a: var
  def tap_error({:ok, _} = result, _fun), do: result

  def tap_error({:error, reason} = result, fun) do
    fun.(reason)
    result
  end
end
