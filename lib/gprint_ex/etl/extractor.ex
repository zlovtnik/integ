defmodule GprintEx.ETL.Extractor do
  @moduledoc """
  Behaviour for ETL extractors.
  """

  @doc """
  Extract data from a source.
  """
  @callback extract(opts :: keyword(), context :: map()) ::
              {:ok, [map()]} | {:error, term()}
end
