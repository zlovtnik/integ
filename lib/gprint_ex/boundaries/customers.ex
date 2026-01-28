defmodule GprintEx.Boundaries.Customers do
  @moduledoc """
  Customer context — public API for customer operations.
  Orchestrates domain logic with repository effects.
  """

  alias GprintEx.Domain.{Customer, Types}
  alias GprintEx.Infrastructure.Repo.Queries.CustomerQueries
  alias GprintEx.Result

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @doc "Create a new customer"
  @spec create(tenant_context(), map()) :: Result.t(Customer.t())
  def create(%{tenant_id: tenant_id, user: user}, params) do
    with {:ok, customer} <- Customer.new(Map.put(params, :tenant_id, tenant_id)),
         {:ok, id} <- CustomerQueries.insert(customer, user),
         {:ok, created} <- get_by_id(%{tenant_id: tenant_id}, id) do
      {:ok, created}
    end
  end

  @doc "Get customer by ID"
  @spec get_by_id(tenant_context(), pos_integer()) :: Result.t(Customer.t())
  def get_by_id(%{tenant_id: tenant_id}, id) do
    case CustomerQueries.find_by_id(tenant_id, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> Customer.from_row(row)
      {:error, _} = err -> err
    end
  end

  @doc "Get customer by code"
  @spec get_by_code(tenant_context(), String.t()) :: Result.t(Customer.t())
  def get_by_code(%{tenant_id: tenant_id}, code) do
    case CustomerQueries.find_by_code(tenant_id, code) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> Customer.from_row(row)
      {:error, _} = err -> err
    end
  end

  @doc "List customers with filters and pagination"
  @spec list(tenant_context(), keyword()) :: Result.t({[Customer.t()], Types.pagination()})
  def list(%{tenant_id: tenant_id}, opts \\ []) do
    filters = Keyword.put(opts, :tenant_id, tenant_id)
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)

    with {:ok, rows} <- CustomerQueries.list(filters),
         {:ok, total} <- CustomerQueries.count(tenant_id, opts),
         {:ok, customers} <- Result.traverse(rows, &Customer.from_row/1) do
      pagination = Types.paginate(total, page, page_size)
      {:ok, {customers, pagination}}
    end
  end

  @doc "Update customer"
  @spec update(tenant_context(), pos_integer(), map()) :: Result.t(Customer.t())
  def update(%{tenant_id: tenant_id, user: user}, id, changes) do
    with {:ok, _existing} <- get_by_id(%{tenant_id: tenant_id}, id),
         :ok <- CustomerQueries.update(tenant_id, id, changes, user),
         {:ok, updated} <- get_by_id(%{tenant_id: tenant_id}, id) do
      {:ok, updated}
    end
  end

  @doc "Delete customer"
  @spec delete(tenant_context(), pos_integer()) :: :ok | {:error, term()}
  def delete(%{tenant_id: tenant_id}, id) do
    with {:ok, _existing} <- get_by_id(%{tenant_id: tenant_id}, id) do
      CustomerQueries.delete(tenant_id, id)
    end
  end
end
