defmodule GprintEx.Infrastructure.Repo.Queries.ContractQueries do
  @moduledoc """
  Raw SQL queries for contracts table.
  Uses Oracle positional parameters (:1, :2, etc.)
  """

  alias GprintEx.Infrastructure.Repo.OracleRepoSupervisor, as: OracleRepo

  @base_select """
  SELECT
    id, tenant_id, contract_number, contract_type,
    customer_id, start_date, end_date, duration_months,
    auto_renew, total_value, payment_terms, billing_cycle,
    status, signed_at, signed_by, notes,
    created_at, updated_at, created_by, updated_by
  FROM contracts
  """

  @spec find_by_id(String.t(), pos_integer()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_id(tenant_id, id) do
    sql = @base_select <> " WHERE tenant_id = :1 AND id = :2"
    OracleRepo.query_one(sql, [tenant_id, id])
  end

  @spec find_by_number(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_number(tenant_id, contract_number) do
    sql = @base_select <> " WHERE tenant_id = :1 AND contract_number = :2"
    OracleRepo.query_one(sql, [tenant_id, contract_number])
  end

  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(filters) do
    tenant_id = Keyword.fetch!(filters, :tenant_id)
    page = Keyword.get(filters, :page, 1)
    page_size = Keyword.get(filters, :page_size, 20)
    offset = (page - 1) * page_size

    {where_clauses, params} = build_filters(filters, ["tenant_id = :1"], [tenant_id])

    param_count = length(params)

    sql = """
    SELECT * FROM (
      #{@base_select}
      WHERE #{Enum.join(where_clauses, " AND ")}
      ORDER BY created_at DESC
    )
    OFFSET :#{param_count + 1} ROWS
    FETCH NEXT :#{param_count + 2} ROWS ONLY
    """

    final_params = params ++ [offset, page_size]
    OracleRepo.query(sql, final_params)
  end

  @spec insert(map(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(contract, created_by) do
    sql = """
    INSERT INTO contracts (
      tenant_id, contract_number, contract_type, customer_id,
      start_date, end_date, duration_months, auto_renew,
      total_value, payment_terms, billing_cycle, status,
      notes, created_by
    ) VALUES (
      :1, :2, :3, :4, :5, :6, :7, :8, :9, :10, :11, :12, :13, :14
    )
    RETURNING id INTO :15
    """

    params = [
      contract.tenant_id,
      contract.contract_number,
      contract.contract_type && contract.contract_type |> Atom.to_string() |> String.upcase(),
      contract.customer_id,
      contract.start_date,
      contract.end_date,
      contract.duration_months,
      if(contract.auto_renew, do: 1, else: 0),
      contract.total_value && Decimal.to_string(contract.total_value),
      contract.payment_terms,
      contract.billing_cycle,
      contract.status && contract.status |> Atom.to_string() |> String.upcase(),
      contract.notes,
      created_by
    ]

    OracleRepo.execute(sql, params)
  end

  @spec update_status(String.t(), pos_integer(), atom(), String.t()) :: :ok | {:error, term()}
  def update_status(tenant_id, id, new_status, updated_by) do
    sql = """
    UPDATE contracts
    SET status = :3, updated_by = :4, updated_at = SYSTIMESTAMP
    WHERE tenant_id = :1 AND id = :2
    """

    status_str = new_status |> Atom.to_string() |> String.upcase()
    OracleRepo.execute(sql, [tenant_id, id, status_str, updated_by])
  end

  @spec insert_item(String.t(), pos_integer(), map()) ::
          :ok | {:ok, pos_integer()} | {:error, term()}
  def insert_item(tenant_id, contract_id, item) do
    sql = """
    INSERT INTO contract_items (
      tenant_id, contract_id, line_number, service_id,
      description, quantity, unit_price, discount_pct, total_price, notes
    ) VALUES (
      :1, :2, :3, :4, :5, :6, :7, :8, :9, :10
    )
    RETURNING id INTO :11
    """

    params = [
      tenant_id,
      contract_id,
      item.line_number || 1,
      item.service_id,
      item.description,
      safe_decimal_to_string(item.quantity, "1"),
      safe_decimal_to_string(item.unit_price, "0"),
      safe_decimal_to_string(item.discount_pct, "0"),
      item.total_price && Decimal.to_string(item.total_price),
      item.notes
    ]

    OracleRepo.execute(sql, params)
  end

  # Safely convert Decimal to string, returning default for nil
  defp safe_decimal_to_string(nil, default), do: default
  defp safe_decimal_to_string(%Decimal{} = d, _default), do: Decimal.to_string(d)
  defp safe_decimal_to_string(value, _default) when is_binary(value), do: value
  defp safe_decimal_to_string(_, default), do: default

  @spec list_items(String.t(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def list_items(tenant_id, contract_id) do
    sql = """
    SELECT
      id, tenant_id, contract_id, line_number, service_id,
      description, quantity, unit_price, discount_pct, total_price,
      notes, created_at, updated_at
    FROM contract_items
    WHERE tenant_id = :1 AND contract_id = :2
    ORDER BY line_number
    """

    OracleRepo.query(sql, [tenant_id, contract_id])
  end

  @spec insert_history(map()) :: :ok | {:error, term()}
  def insert_history(params) do
    sql = """
    INSERT INTO contract_history (
      tenant_id, contract_id, action, field_changed,
      old_value, new_value, performed_by
    ) VALUES (
      :1, :2, :3, :4, :5, :6, :7
    )
    """

    OracleRepo.execute(sql, [
      params.tenant_id,
      params.contract_id,
      params.action |> to_string() |> String.upcase(),
      params.field_changed,
      params.old_value,
      params.new_value,
      params.performed_by
    ])
  end

  @spec count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(tenant_id, filters \\ []) do
    {where_clauses, params} = build_filters(filters, ["tenant_id = :1"], [tenant_id])

    sql = """
    SELECT COUNT(*) AS cnt
    FROM contracts
    WHERE #{Enum.join(where_clauses, " AND ")}
    """

    case OracleRepo.query_one(sql, params) do
      {:ok, %{cnt: count}} -> {:ok, count}
      {:error, _} = err -> err
    end
  end

  # Private

  defp build_filters(filters, clauses, params) do
    # Check if active_only is set - if so, skip any :status filter
    has_active_only = Keyword.get(filters, :active_only, false)

    Enum.reduce(filters, {clauses, params}, fn
      {:status, status}, {c, p} when not has_active_only ->
        {c ++ ["status = :#{length(p) + 1}"], p ++ [status |> to_string() |> String.upcase()]}

      {:status, _status}, acc ->
        # Skip :status when :active_only is true to avoid conflicting conditions
        acc

      {:customer_id, customer_id}, {c, p} ->
        {c ++ ["customer_id = :#{length(p) + 1}"], p ++ [customer_id]}

      {:active_only, true}, {c, p} ->
        {c ++ ["status = 'ACTIVE'"], p}

      {:expiring_within_days, days}, {c, p} when is_integer(days) ->
        {c ++ ["end_date BETWEEN SYSDATE AND SYSDATE + :#{length(p) + 1}"], p ++ [days]}

      {:search, term}, {c, p} when is_binary(term) ->
        escaped_term =
          term
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")
          |> String.upcase()

        like = "%#{escaped_term}%"
        {c ++ ["UPPER(contract_number) LIKE :#{length(p) + 1} ESCAPE '\\'"], p ++ [like]}

      _, acc ->
        acc
    end)
  end
end
