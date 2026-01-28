defmodule GprintEx.Integration.DB.ContractOperations do
  @moduledoc """
  Database operations for Contract integration.

  Wraps PL/SQL CONTRACT_PKG calls with proper error handling,
  telemetry, and result mapping to domain structs.

  All operations delegate data manipulation to PL/SQL while
  Elixir handles orchestration and type conversion.
  """

  require Logger

  alias GprintEx.Domain.Contract
  alias GprintEx.Infrastructure.Repo.OracleConnection
  alias GprintEx.Result

  @doc """
  Insert a new contract via CONTRACT_PKG.insert_contract.
  """
  @spec insert(Contract.t(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(%Contract{} = contract, user) do
    sql = """
    DECLARE
      v_contract contract_t;
      v_result NUMBER;
    BEGIN
      v_contract := contract_t(
        NULL,
        :tenant_id,
        :contract_number,
        :contract_name,
        :customer_id,
        :start_date,
        :end_date,
        :status,
        :total_value,
        :currency_code
      );
      v_result := contract_pkg.insert_contract(v_contract, :user);
      :out := v_result;
    END;
    """

    params = [
      tenant_id: contract.tenant_id,
      contract_number: contract.contract_number,
      contract_name: contract.contract_name,
      customer_id: contract.customer_id,
      start_date: format_date(contract.start_date),
      end_date: format_date(contract.end_date),
      status: to_string(contract.status),
      total_value: contract.total_value,
      currency_code: contract.currency_code || "BRL",
      user: user,
      out: {:out, :integer}
    ]

    case execute_with_telemetry(:insert_contract, sql, params) do
      {:ok, %{out: id}} -> {:ok, id}
      {:ok, [id]} -> {:ok, id}
      {:error, error} -> map_oracle_error(error)
    end
  end

  @doc """
  Bulk insert contracts via CONTRACT_PKG.bulk_insert_contracts.
  """
  @spec bulk_insert([Contract.t()], String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def bulk_insert(contracts, user) when is_list(contracts) do
    # Convert to JSON array for PL/SQL processing
    contracts_json =
      contracts
      |> Enum.map(&contract_to_map/1)
      |> Jason.encode!()

    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := contract_pkg.bulk_insert_contracts(:contracts_json, :user);
      :out := v_count;
    END;
    """

    params = [
      contracts_json: contracts_json,
      user: user,
      out: {:out, :integer}
    ]

    case execute_with_telemetry(:bulk_insert_contracts, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:ok, [count]} -> {:ok, count}
      {:error, error} -> map_oracle_error(error)
    end
  end

  @doc """
  Get contract by ID via CONTRACT_PKG.get_contract_by_id.
  """
  @spec get_by_id(String.t(), pos_integer()) :: {:ok, Contract.t()} | {:error, :not_found | term()}
  def get_by_id(tenant_id, id) do
    sql = """
    SELECT id, tenant_id, contract_number, contract_name, customer_id,
           start_date, end_date, status, total_value, currency_code,
           created_by, created_at, updated_by, updated_at
    FROM contracts
    WHERE tenant_id = :1 AND id = :2
    """

    case OracleConnection.query(:gprint_pool, sql, [tenant_id, id]) do
      {:ok, [row]} -> Contract.from_row(row)
      {:ok, []} -> {:error, :not_found}
      {:error, error} -> map_oracle_error(error)
    end
  end

  @doc """
  Update contract status via CONTRACT_PKG.update_contract_status.
  """
  @spec update_status(String.t(), pos_integer(), atom(), String.t()) ::
          {:ok, Contract.t()} | {:error, term()}
  def update_status(tenant_id, id, new_status, user) do
    sql = """
    DECLARE
      v_result NUMBER;
    BEGIN
      v_result := contract_pkg.update_contract_status(:tenant_id, :id, :new_status, :user);
      :out := v_result;
    END;
    """

    params = [
      tenant_id: tenant_id,
      id: id,
      new_status: to_string(new_status),
      user: user,
      out: {:out, :integer}
    ]

    case execute_with_telemetry(:update_contract_status, sql, params) do
      {:ok, _} -> get_by_id(tenant_id, id)
      {:error, %{code: -20001}} -> {:error, :invalid_transition}
      {:error, error} -> map_oracle_error(error)
    end
  end

  @doc """
  Validate contract via CONTRACT_PKG.validate_contract.
  """
  @spec validate(Contract.t()) :: {:ok, Contract.t()} | {:error, :validation_failed, [String.t()]}
  def validate(%Contract{} = contract) do
    sql = """
    DECLARE
      v_contract contract_t;
      v_result validation_result_t;
    BEGIN
      v_contract := contract_t(
        :id, :tenant_id, :contract_number, :contract_name, :customer_id,
        :start_date, :end_date, :status, :total_value, :currency_code
      );
      v_result := contract_pkg.validate_contract(v_contract);
      :is_valid := CASE WHEN v_result.is_valid THEN 1 ELSE 0 END;
      :messages := v_result.message;
    END;
    """

    params = contract_to_params(contract) ++ [
      is_valid: {:out, :integer},
      messages: {:out, :string}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{is_valid: 1}} ->
        {:ok, contract}

      {:ok, %{is_valid: 0, messages: messages}} ->
        errors = String.split(messages || "", ";") |> Enum.reject(&(&1 == ""))
        {:error, :validation_failed, errors}

      {:error, error} ->
        map_oracle_error(error)
    end
  end

  @doc """
  Check if status transition is valid.
  """
  @spec valid_transition?(atom(), atom()) :: boolean()
  def valid_transition?(from_status, to_status) do
    sql = """
    SELECT contract_pkg.is_valid_transition(:from_status, :to_status) FROM DUAL
    """

    case OracleConnection.query(:gprint_pool, sql, [to_string(from_status), to_string(to_status)]) do
      {:ok, [[1]]} -> true
      {:ok, [[0]]} -> false
      _ -> false
    end
  end

  @doc """
  Process auto-renewals via CONTRACT_PKG.process_auto_renewals.
  """
  @spec process_auto_renewals(String.t(), String.t()) :: {:ok, non_neg_integer()} | {:error, term()}
  def process_auto_renewals(tenant_id, user) do
    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := contract_pkg.process_auto_renewals(:tenant_id, :user);
      :out := v_count;
    END;
    """

    params = [tenant_id: tenant_id, user: user, out: {:out, :integer}]

    case execute_with_telemetry(:process_auto_renewals, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:error, error} -> map_oracle_error(error)
    end
  end

  # Private functions

  defp execute_with_telemetry(operation, sql, params) do
    start_time = System.monotonic_time()

    result = OracleConnection.execute(:gprint_pool, sql, params)

    duration = System.monotonic_time() - start_time

    :telemetry.execute(
      [:gprint_ex, :integration, :db, :contract],
      %{duration: duration},
      %{operation: operation, success: match?({:ok, _}, result)}
    )

    result
  end

  defp contract_to_map(%Contract{} = contract) do
    %{
      tenant_id: contract.tenant_id,
      contract_number: contract.contract_number,
      contract_name: contract.contract_name,
      customer_id: contract.customer_id,
      start_date: format_date(contract.start_date),
      end_date: format_date(contract.end_date),
      status: to_string(contract.status),
      total_value: contract.total_value,
      currency_code: contract.currency_code
    }
  end

  defp contract_to_params(%Contract{} = contract) do
    [
      id: contract.id,
      tenant_id: contract.tenant_id,
      contract_number: contract.contract_number,
      contract_name: contract.contract_name,
      customer_id: contract.customer_id,
      start_date: format_date(contract.start_date),
      end_date: format_date(contract.end_date),
      status: to_string(contract.status),
      total_value: contract.total_value,
      currency_code: contract.currency_code || "BRL"
    ]
  end

  defp format_date(nil), do: nil
  defp format_date(%Date{} = date), do: Date.to_iso8601(date)
  defp format_date(date), do: date

  defp map_oracle_error(%{code: 1, message: msg}) do
    {:error, :unique_violation, msg}
  end

  defp map_oracle_error(%{code: 2291, message: msg}) do
    {:error, :foreign_key_violation, msg}
  end

  defp map_oracle_error(%{code: code, message: msg}) when code >= -20999 and code <= -20000 do
    # Application-defined errors
    {:error, :business_error, msg}
  end

  defp map_oracle_error(error) do
    Logger.error("Oracle error: #{inspect(error)}")
    {:error, :db_error}
  end
end
