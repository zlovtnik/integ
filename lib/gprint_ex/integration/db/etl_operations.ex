defmodule GprintEx.Integration.DB.ETLOperations do
  @moduledoc """
  Database operations for ETL processing.

  Wraps PL/SQL ETL_PKG calls for staging session management,
  data transformation, validation, and promotion.
  """

  require Logger

  alias GprintEx.Infrastructure.Repo.OracleConnection

  @type session_status :: :created | :loading | :transforming | :validating | :promoting | :completed | :failed | :rolled_back

  @doc """
  Create a new staging session via ETL_PKG.create_staging_session.
  """
  @spec create_session(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:error, term()}
  def create_session(tenant_id, source_system, created_by) do
    sql = """
    DECLARE
      v_session_id VARCHAR2(50);
    BEGIN
      v_session_id := etl_pkg.create_staging_session(:tenant_id, :source_system, :created_by);
      :out := v_session_id;
    END;
    """

    params = [
      tenant_id: tenant_id,
      source_system: source_system,
      created_by: created_by,
      out: {:out, :string}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: session_id}} -> {:ok, session_id}
      {:ok, [session_id]} -> {:ok, session_id}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Load data to staging via ETL_PKG.load_to_staging.
  """
  @spec load_to_staging(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, pos_integer()} | {:error, term()}
  def load_to_staging(session_id, entity_type, entity_id, raw_data) do
    sql = """
    DECLARE
      v_id NUMBER;
    BEGIN
      v_id := etl_pkg.load_to_staging(:session_id, :entity_type, :entity_id, :raw_data);
      :out := v_id;
    END;
    """

    raw_json = if is_map(raw_data), do: Jason.encode!(raw_data), else: raw_data

    params = [
      session_id: session_id,
      entity_type: entity_type,
      entity_id: entity_id,
      raw_data: raw_json,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: id}} -> {:ok, id}
      {:ok, [id]} -> {:ok, id}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Bulk load data to staging.
  """
  @spec bulk_load_to_staging(String.t(), String.t(), [map()]) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def bulk_load_to_staging(session_id, entity_type, records) when is_list(records) do
    results =
      Enum.map(records, fn record ->
        entity_id = Map.get(record, :id) || Map.get(record, "id") || UUID.uuid4()
        load_to_staging(session_id, entity_type, to_string(entity_id), record)
      end)

    successes = Enum.count(results, &match?({:ok, _}, &1))
    failures = Enum.filter(results, &match?({:error, _}, &1))

    if Enum.empty?(failures) do
      {:ok, successes}
    else
      {:error, {:partial_failure, successes, length(failures)}}
    end
  end

  @doc """
  Transform contracts in staging via ETL_PKG.transform_contracts.
  """
  @spec transform_contracts(String.t(), map() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def transform_contracts(session_id, transform_rules \\ nil) do
    rules_json = if transform_rules, do: Jason.encode!(transform_rules), else: nil

    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := etl_pkg.transform_contracts(:session_id, :rules);
      :out := v_count;
    END;
    """

    params = [
      session_id: session_id,
      rules: rules_json,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:ok, [count]} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Transform customers in staging via ETL_PKG.transform_customers.
  """
  @spec transform_customers(String.t(), map() | nil) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def transform_customers(session_id, transform_rules \\ nil) do
    rules_json = if transform_rules, do: Jason.encode!(transform_rules), else: nil

    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := etl_pkg.transform_customers(:session_id, :rules);
      :out := v_count;
    END;
    """

    params = [
      session_id: session_id,
      rules: rules_json,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:ok, [count]} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Validate staging data via ETL_PKG.validate_staging_data.
  Returns validation results as a list of issues.
  """
  @spec validate_staging_data(String.t()) ::
          {:ok, [map()]} | {:error, term()}
  def validate_staging_data(session_id) do
    sql = """
    SELECT entity_type, entity_id, field_name, error_code, error_message, severity
    FROM TABLE(etl_pkg.validate_staging_data(:session_id))
    """

    case OracleConnection.query(:gprint_pool, sql, [session_id]) do
      {:ok, rows} ->
        issues = Enum.map(rows, fn row ->
          %{
            entity_type: row[:entity_type],
            entity_id: row[:entity_id],
            field_name: row[:field_name],
            error_code: row[:error_code],
            error_message: row[:error_message],
            severity: row[:severity]
          }
        end)
        {:ok, issues}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Promote contracts from staging via ETL_PKG.promote_contracts.
  """
  @spec promote_contracts(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def promote_contracts(session_id, promoted_by) do
    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := etl_pkg.promote_contracts(:session_id, :promoted_by);
      :out := v_count;
    END;
    """

    params = [
      session_id: session_id,
      promoted_by: promoted_by,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:ok, [count]} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Promote customers from staging via ETL_PKG.promote_customers.
  """
  @spec promote_customers(String.t(), String.t()) ::
          {:ok, non_neg_integer()} | {:error, term()}
  def promote_customers(session_id, promoted_by) do
    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := etl_pkg.promote_customers(:session_id, :promoted_by);
      :out := v_count;
    END;
    """

    params = [
      session_id: session_id,
      promoted_by: promoted_by,
      out: {:out, :integer}
    ]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:ok, [count]} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Rollback a staging session via ETL_PKG.rollback_session.
  """
  @spec rollback_session(String.t()) :: :ok | {:error, term()}
  def rollback_session(session_id) do
    sql = """
    BEGIN
      etl_pkg.rollback_session(:session_id);
    END;
    """

    case OracleConnection.execute(:gprint_pool, sql, [session_id: session_id]) do
      {:ok, _} -> :ok
      {:error, error} -> {:error, error}
    end
  end

  @doc """
  Get session status and counts.
  """
  @spec get_session_status(String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get_session_status(session_id) do
    sql = """
    SELECT session_id, tenant_id, source_system, status,
           total_records, valid_records, error_records, promoted_records,
           created_at, completed_at
    FROM etl_sessions
    WHERE session_id = :1
    """

    case OracleConnection.query(:gprint_pool, sql, [session_id]) do
        status = String.downcase(row[:status] || "unknown")
        status_atom = case status do
          "created" -> :created
          "loading" -> :loading
          "transforming" -> :transforming
          "validating" -> :validating
          "promoting" -> :promoting
          "completed" -> :completed
          "failed" -> :failed
          "rolled_back" -> :rolled_back
          _ -> :unknown
        end

        {:ok, %{
          session_id: row[:session_id],
          tenant_id: row[:tenant_id],
          source_system: row[:source_system],
          status: status_atom,
          total_records: row[:total_records] || 0,
          valid_records: row[:valid_records] || 0,
          error_records: row[:error_records] || 0,
          promoted_records: row[:promoted_records] || 0,
          created_at: row[:created_at],
          completed_at: row[:completed_at]
        }}

      {:ok, []} ->
        {:error, :not_found}

      {:error, error} ->
        {:error, error}
    end
  end

  @doc """
  Cleanup old sessions via ETL_PKG.cleanup_old_sessions.
  """
  @spec cleanup_old_sessions(non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup_old_sessions(retention_days \\ 30) do
    sql = """
    DECLARE
      v_count NUMBER;
    BEGIN
      v_count := etl_pkg.cleanup_old_sessions(:retention_days);
      :out := v_count;
    END;
    """

    params = [retention_days: retention_days, out: {:out, :integer}]

    case OracleConnection.execute(:gprint_pool, sql, params) do
      {:ok, %{out: count}} -> {:ok, count}
      {:ok, [count]} -> {:ok, count}
      {:error, error} -> {:error, error}
    end
  end
end
