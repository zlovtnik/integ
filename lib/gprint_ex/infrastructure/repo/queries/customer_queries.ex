defmodule GprintEx.Infrastructure.Repo.Queries.CustomerQueries do
  @moduledoc """
  Raw SQL queries for customers table.
  Uses Oracle positional parameters (:1, :2, etc.)
  """

  alias GprintEx.Infrastructure.Repo.OracleRepoSupervisor, as: OracleRepo

  @base_select """
  SELECT
    id, tenant_id, customer_code, customer_type,
    name, trade_name, tax_id, state_reg, municipal_reg,
    email, phone, mobile,
    address_street, address_number, address_comp,
    address_district, address_city, address_state,
    address_zip, address_country,
    active, notes, created_at, updated_at,
    created_by, updated_by
  FROM customers
  """

  @spec find_by_id(String.t(), pos_integer()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_id(tenant_id, id) do
    sql = @base_select <> " WHERE tenant_id = :1 AND id = :2"
    OracleRepo.query_one(sql, [tenant_id, id])
  end

  @spec find_by_code(String.t(), String.t()) :: {:ok, map() | nil} | {:error, term()}
  def find_by_code(tenant_id, code) do
    sql = @base_select <> " WHERE tenant_id = :1 AND customer_code = :2"
    OracleRepo.query_one(sql, [tenant_id, code])
  end

  @spec list(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list(filters) do
    tenant_id = Keyword.fetch!(filters, :tenant_id)
    page = Keyword.get(filters, :page, 1)
    page_size = Keyword.get(filters, :page_size, 20)
    offset = (page - 1) * page_size

    {where_clauses, params} = build_filters(filters, ["tenant_id = :1"], [tenant_id])

    param_count = length(params)
    offset_placeholder = ":#{param_count + 1}"
    limit_placeholder = ":#{param_count + 2}"

    sql = """
    SELECT * FROM (
      #{@base_select}
      WHERE #{Enum.join(where_clauses, " AND ")}
      ORDER BY name
    )
    OFFSET #{offset_placeholder} ROWS
    FETCH NEXT #{limit_placeholder} ROWS ONLY
    """

    final_params = params ++ [offset, page_size]
    OracleRepo.query(sql, final_params)
  end

  @spec insert(map(), String.t()) :: {:ok, pos_integer()} | {:error, term()}
  def insert(customer, created_by) do
    sql = """
    INSERT INTO customers (
      tenant_id, customer_code, customer_type, name, trade_name,
      tax_id, email, phone, active, created_by
    ) VALUES (
      :1, :2, :3, :4, :5, :6, :7, :8, :9, :10
    )
    RETURNING id INTO :11
    """

    params = [
      customer.tenant_id,
      customer.customer_code,
      safe_atom_to_string(customer.customer_type),
      customer.name,
      customer.trade_name,
      customer.tax_id,
      customer.email,
      customer.phone,
      if(customer.active, do: 1, else: 0),
      created_by
    ]

    OracleRepo.execute(sql, params)
  end

  # Safely convert atom or string to uppercase string
  defp safe_atom_to_string(nil), do: nil

  defp safe_atom_to_string(value) when is_atom(value),
    do: value |> Atom.to_string() |> String.upcase()

  defp safe_atom_to_string(value) when is_binary(value), do: String.upcase(value)
  defp safe_atom_to_string(value), do: to_string(value) |> String.upcase()

  @spec update(String.t(), pos_integer(), map(), String.t()) :: :ok | {:error, term()}
  def update(tenant_id, id, changes, updated_by) do
    {set_clauses, params} = build_update_clauses(changes, 3)

    # Handle empty set_clauses - only update updated_by and updated_at
    sql =
      if Enum.empty?(set_clauses) do
        """
        UPDATE customers
        SET updated_by = :3, updated_at = SYSTIMESTAMP
        WHERE tenant_id = :1 AND id = :2
        """
      else
        """
        UPDATE customers
        SET #{Enum.join(set_clauses, ", ")}, updated_by = :#{length(params) + 3}, updated_at = SYSTIMESTAMP
        WHERE tenant_id = :1 AND id = :2
        """
      end

    final_params =
      if Enum.empty?(set_clauses) do
        [tenant_id, id, updated_by]
      else
        [tenant_id, id] ++ params ++ [updated_by]
      end

    OracleRepo.execute(sql, final_params)
  end

  @spec delete(String.t(), pos_integer()) :: :ok | {:error, term()}
  def delete(tenant_id, id) do
    sql = "DELETE FROM customers WHERE tenant_id = :1 AND id = :2"
    OracleRepo.execute(sql, [tenant_id, id])
  end

  @spec count(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def count(tenant_id, filters \\ []) do
    {where_clauses, params} = build_filters(filters, ["tenant_id = :1"], [tenant_id])

    sql = """
    SELECT COUNT(*) AS cnt
    FROM customers
    WHERE #{Enum.join(where_clauses, " AND ")}
    """

    case OracleRepo.query_one(sql, params) do
      {:ok, %{cnt: count}} -> {:ok, count}
      {:error, _} = err -> err
    end
  end

  # Private

  defp build_filters(filters, clauses, params) do
    Enum.reduce(filters, {clauses, params}, fn
      {:active, true}, {c, p} ->
        {c ++ ["active = :#{length(p) + 1}"], p ++ [1]}

      {:active, false}, {c, p} ->
        {c ++ ["active = :#{length(p) + 1}"], p ++ [0]}

      {:search, term}, {c, p} when is_binary(term) ->
        escaped_term =
          term
          |> String.replace("\\", "\\\\")
          |> String.replace("%", "\\%")
          |> String.replace("_", "\\_")
          |> String.upcase()

        like = "%#{escaped_term}%"

        {c ++
           [
             "(UPPER(name) LIKE :#{length(p) + 1} ESCAPE '\\' OR customer_code LIKE :#{length(p) + 2} ESCAPE '\\')"
           ], p ++ [like, like]}

      {:customer_type, type}, {c, p} ->
        {c ++ ["customer_type = :#{length(p) + 1}"], p ++ [type |> to_string() |> String.upcase()]}

      _, acc ->
        acc
    end)
  end

  # Whitelist of allowed column names for updates (prevents SQL injection)
  @allowed_update_columns ~w(name trade_name tax_id email phone active notes
                              address_street address_number address_comp
                              address_district address_city address_state
                              address_zip address_country customer_type)a

  defp build_update_clauses(changes, start_idx) do
    changes
    |> Map.to_list()
    |> Enum.filter(fn {key, _value} -> allowed_column?(key) end)
    |> Enum.with_index(start_idx)
    |> Enum.reduce({[], []}, fn {{key, value}, idx}, {clauses, params} ->
      column = key |> to_string() |> String.downcase()
      {clauses ++ ["#{column} = :#{idx}"], params ++ [normalize_value(value)]}
    end)
  end

  defp allowed_column?(key) when is_atom(key), do: key in @allowed_update_columns

  defp allowed_column?(key) when is_binary(key) do
    try do
      atom_key = String.to_existing_atom(key)
      atom_key in @allowed_update_columns
    rescue
      ArgumentError -> false
    end
  end

  defp allowed_column?(_), do: false

  defp normalize_value(true), do: 1
  defp normalize_value(false), do: 0
  defp normalize_value(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp normalize_value(value), do: value
end
