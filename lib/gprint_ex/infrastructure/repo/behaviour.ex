defmodule GprintEx.Infrastructure.Repo.Behaviour do
  @moduledoc """
  Behaviour for repository implementations.
  Enables testing with mocks.
  """

  @type tenant_id :: String.t()
  @type id :: pos_integer()
  @type row :: map()
  @type filters :: keyword()

  @callback find_by_id(tenant_id(), id()) :: {:ok, row() | nil} | {:error, term()}
  @callback list(tenant_id(), filters()) :: {:ok, [row()]} | {:error, term()}
  @callback insert(map(), String.t()) :: {:ok, id()} | {:error, term()}
  @callback update(tenant_id(), id(), map(), String.t()) :: :ok | {:error, term()}
  @callback delete(tenant_id(), id()) :: :ok | {:error, term()}
end
