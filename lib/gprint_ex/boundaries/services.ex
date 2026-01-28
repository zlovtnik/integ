defmodule GprintEx.Boundaries.Services do
  @moduledoc """
  Services context — public API for service catalog operations.
  """

  alias GprintEx.Domain.{Service, Types}
  alias GprintEx.Result

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  # Placeholder service queries (would be similar to CustomerQueries)
  # TODO: Implement ServiceQueries module

  @doc "Create a new service"
  @spec create(tenant_context(), map()) :: Result.t(Service.t())
  def create(%{tenant_id: tenant_id}, params) do
    Service.new(Map.put(params, :tenant_id, tenant_id))
  end

  @doc "Get service by ID"
  @spec get_by_id(tenant_context(), pos_integer()) :: Result.t(Service.t())
  def get_by_id(%{tenant_id: _tenant_id}, _id) do
    # TODO: Implement with ServiceQueries
    {:error, :not_found}
  end

  @doc "List services with filters and pagination"
  @spec list(tenant_context(), keyword()) :: Result.t({[Service.t()], Types.pagination()})
  def list(%{tenant_id: _tenant_id}, opts \\ []) do
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)
    pagination = Types.paginate(0, page, page_size)
    # TODO: Implement with ServiceQueries
    {:ok, {[], pagination}}
  end

  @doc "Update service"
  @spec update(tenant_context(), pos_integer(), map()) :: Result.t(Service.t())
  def update(%{tenant_id: _tenant_id}, _id, _changes) do
    # TODO: Implement with ServiceQueries
    {:error, :not_found}
  end

  @doc "Delete service"
  @spec delete(tenant_context(), pos_integer()) :: :ok | {:error, term()}
  def delete(%{tenant_id: _tenant_id}, _id) do
    # TODO: Implement with ServiceQueries
    :ok
  end
end
