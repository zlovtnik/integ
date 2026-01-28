defmodule GprintEx.ETL.Transformer do
  @moduledoc """
  Behaviour for ETL transformers.
  """

  @doc """
  Transform data.
  """
  @callback transform(data :: term(), opts :: keyword(), context :: map()) ::
              {:ok, term()} | {:error, term()}
end
