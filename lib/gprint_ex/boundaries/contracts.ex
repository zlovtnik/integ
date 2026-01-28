defmodule GprintEx.Boundaries.Contracts do
  @moduledoc """
  Contract context — public API for contract operations.
  Orchestrates domain logic with repository effects.
  """

  alias GprintEx.Domain.{Contract, ContractItem, Types}
  alias GprintEx.Infrastructure.Repo.Queries.ContractQueries
  alias GprintEx.Infrastructure.Repo.OracleRepoSupervisor, as: OracleRepo
  alias GprintEx.Result

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @doc "Create a new contract with items"
  @spec create(tenant_context(), map()) :: Result.t(Contract.t())
  def create(%{tenant_id: tenant_id, user: user} = _ctx, params) do
    with {:ok, contract} <- Contract.new(Map.put(params, :tenant_id, tenant_id)),
         {:ok, items} <- validate_items(params[:items] || params["items"] || []),
         {:ok, contract_with_totals} <- Contract.calculate_totals(contract, items),
         {:ok, contract_id} <-
           OracleRepo.transaction(fn _conn ->
             # Note: _conn is the worker connection for executing queries within transaction
             # Currently queries use the pool directly; for true transaction isolation,
             # queries would need to be updated to accept a connection parameter
             with {:ok, id} <- ContractQueries.insert(contract_with_totals, user),
                  :ok <- insert_items(tenant_id, id, items) do
               {:ok, id}
             end
           end),
         {:ok, created} <- get_by_id(%{tenant_id: tenant_id}, contract_id) do
      {:ok, created}
    end
  end

  @doc "Get contract by ID"
  @spec get_by_id(tenant_context(), pos_integer()) :: Result.t(Contract.t())
  def get_by_id(%{tenant_id: tenant_id}, id) do
    case ContractQueries.find_by_id(tenant_id, id) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> Contract.from_row(row)
      {:error, _} = err -> err
    end
  end

  @doc "Get contract by number"
  @spec get_by_number(tenant_context(), String.t()) :: Result.t(Contract.t())
  def get_by_number(%{tenant_id: tenant_id}, contract_number) do
    case ContractQueries.find_by_number(tenant_id, contract_number) do
      {:ok, nil} -> {:error, :not_found}
      {:ok, row} -> Contract.from_row(row)
      {:error, _} = err -> err
    end
  end

  @doc "List contracts with filters and pagination"
  @spec list(tenant_context(), keyword()) :: Result.t({[Contract.t()], Types.pagination()})
  def list(%{tenant_id: tenant_id}, opts \\ []) do
    filters = Keyword.put(opts, :tenant_id, tenant_id)
    page = Keyword.get(opts, :page, 1)
    page_size = Keyword.get(opts, :page_size, 20)

    with {:ok, rows} <- ContractQueries.list(filters),
         {:ok, total} <- ContractQueries.count(tenant_id, opts),
         {:ok, contracts} <- Result.traverse(rows, &Contract.from_row/1) do
      pagination = Types.paginate(total, page, page_size)
      {:ok, {contracts, pagination}}
    end
  end

  @doc "Update contract"
  @spec update(tenant_context(), pos_integer(), map()) :: Result.t(Contract.t())
  def update(%{tenant_id: tenant_id, user: _user}, id, _changes) do
    # TODO: Implement contract update
    get_by_id(%{tenant_id: tenant_id}, id)
  end

  @doc "Delete contract"
  @spec delete(tenant_context(), pos_integer()) :: :ok | {:error, term()}
  def delete(%{tenant_id: tenant_id}, id) do
    with {:ok, _existing} <- get_by_id(%{tenant_id: tenant_id}, id) do
      # TODO: Implement contract deletion
      :ok
    end
  end

  @doc "Transition contract status (state machine)"
  @spec transition_status(tenant_context(), pos_integer(), atom()) :: Result.t(Contract.t())
  def transition_status(%{tenant_id: tenant_id, user: user}, id, new_status) do
    with {:ok, contract} <- get_by_id(%{tenant_id: tenant_id}, id),
         {:ok, transitioned} <- Contract.transition(contract, new_status),
         :ok <- ContractQueries.update_status(tenant_id, id, new_status, user),
         :ok <- log_history(tenant_id, id, :status_change, contract.status, new_status, user) do
      {:ok, transitioned}
    end
  end

  @doc "List items for a contract"
  @spec list_items(tenant_context(), pos_integer()) :: Result.t([ContractItem.t()])
  def list_items(%{tenant_id: tenant_id}, contract_id) do
    with {:ok, rows} <- ContractQueries.list_items(tenant_id, contract_id) do
      Result.traverse(rows, &ContractItem.from_row/1)
    end
  end

  @doc "Get a specific item"
  @spec get_item(tenant_context(), pos_integer(), pos_integer()) :: Result.t(ContractItem.t())
  def get_item(%{tenant_id: tenant_id}, contract_id, item_id) do
    with {:ok, items} <- list_items(%{tenant_id: tenant_id}, contract_id) do
      case Enum.find(items, &(&1.id == item_id)) do
        nil -> {:error, :not_found}
        item -> {:ok, item}
      end
    end
  end

  @doc "Add item to contract"
  @spec add_item(tenant_context(), pos_integer(), map()) :: Result.t(ContractItem.t())
  def add_item(%{tenant_id: tenant_id}, contract_id, params) do
    item_params =
      params
      |> Map.put(:tenant_id, tenant_id)
      |> Map.put(:contract_id, contract_id)

    with {:ok, item} <- ContractItem.new(item_params),
         {:ok, item_id} <- ContractQueries.insert_item(tenant_id, contract_id, item),
         {:ok, items} <- list_items(%{tenant_id: tenant_id}, contract_id) do
      # Find the inserted item by ID if available, otherwise by line_number
      persisted_item =
        if is_integer(item_id) do
          Enum.find(items, &(&1.id == item_id))
        else
          Enum.find(items, &(&1.line_number == item.line_number))
        end

      case persisted_item do
        nil -> {:ok, item}
        found -> {:ok, found}
      end
    end
  end

  @doc "Update item"
  @spec update_item(tenant_context(), pos_integer(), pos_integer(), map()) ::
          Result.t(ContractItem.t())
  def update_item(%{tenant_id: tenant_id}, contract_id, item_id, _params) do
    # TODO: Implement item update
    get_item(%{tenant_id: tenant_id}, contract_id, item_id)
  end

  @doc "Delete item"
  @spec delete_item(tenant_context(), pos_integer(), pos_integer()) :: :ok | {:error, term()}
  def delete_item(%{tenant_id: tenant_id}, contract_id, item_id) do
    with {:ok, _item} <- get_item(%{tenant_id: tenant_id}, contract_id, item_id) do
      # TODO: Implement item deletion
      :ok
    end
  end

  # Private helpers

  defp validate_items(items) do
    items
    |> Enum.with_index(1)
    |> Result.traverse(fn {item, idx} ->
      item_with_line = Map.put(item, :line_number, idx)

      case ContractItem.new(Map.merge(item_with_line, %{tenant_id: "temp", contract_id: 0})) do
        {:ok, validated} ->
          {:ok, validated}

        {:error, :validation_failed, errors} ->
          {:error, {:item_validation_failed, idx, errors}}
      end
    end)
  end

  defp insert_items(_tenant_id, _contract_id, []), do: :ok

  defp insert_items(tenant_id, contract_id, items) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      updated_item = %{item | tenant_id: tenant_id, contract_id: contract_id}

      case ContractQueries.insert_item(tenant_id, contract_id, updated_item) do
        :ok -> {:cont, :ok}
        {:ok, _} -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:insert_item_failed, reason}}}
      end
    end)
  end

  defp log_history(tenant_id, contract_id, action, old_value, new_value, user) do
    ContractQueries.insert_history(%{
      tenant_id: tenant_id,
      contract_id: contract_id,
      action: action,
      field_changed: "status",
      old_value: to_string(old_value),
      new_value: to_string(new_value),
      performed_by: user
    })
  end
end
