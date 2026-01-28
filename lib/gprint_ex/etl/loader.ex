defmodule GprintEx.ETL.Loader do
  @moduledoc """
  Behaviour for ETL loaders.
  """

  @doc """
  Load data to a destination.
  """
  @callback load(data :: term(), opts :: keyword(), context :: map()) ::
              {:ok, term()} | {:error, term()}
end
