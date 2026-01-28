defmodule GprintEx.Boundaries.ETLSessions do
  @moduledoc """
  Boundary for ETL session management.

  Orchestrates staging session lifecycle: create, load, transform, validate, promote, rollback.
  """

  alias GprintEx.Integration.DB.ETLOperations

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @doc """
  Create a new ETL staging session.
  """
  @spec create(tenant_context(), map()) :: {:ok, map()} | {:error, term()}
  def create(%{tenant_id: tenant_id, user: user}, %{"source_system" => source_system}) do
    with {:ok, session_id} <- ETLOperations.create_session(tenant_id, source_system, user),
         {:ok, status} <- ETLOperations.get_session_status(session_id) do
      {:ok, status}
    end
  end

  def create(_ctx, _params), do: {:error, :validation_failed, ["source_system is required"]}

  @doc """
  Get session status by ID.
  """
  @spec get(tenant_context(), String.t()) :: {:ok, map()} | {:error, :not_found | term()}
  def get(%{tenant_id: _tenant_id}, session_id) do
    ETLOperations.get_session_status(session_id)
  end

  @doc """
  List sessions for tenant (with optional filters).
  """
  @spec list(tenant_context(), map()) :: {:ok, [map()]} | {:error, term()}
  def list(%{tenant_id: tenant_id}, params \\ %{}) do
    status_filter = Map.get(params, "status")
    source_filter = Map.get(params, "source_system")
    limit = Map.get(params, "limit", 50)

    ETLOperations.list_sessions(tenant_id, status_filter, source_filter, limit)
  end

  @doc """
  Load data to staging session.
  """
  @spec load_data(tenant_context(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def load_data(%{tenant_id: _tenant_id, user: _user}, session_id, %{"entity_type" => entity_type, "records" => records})
      when is_list(records) do
    with {:ok, count} <- ETLOperations.bulk_load_to_staging(session_id, entity_type, records),
         {:ok, status} <- ETLOperations.get_session_status(session_id) do
      {:ok, Map.put(status, :loaded_count, count)}
    end
  end

  def load_data(_ctx, _session_id, _params) do
    {:error, :validation_failed, ["entity_type and records array are required"]}
  end

  @doc """
  Transform staging data.
  """
  @spec transform(tenant_context(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def transform(%{tenant_id: _tenant_id}, session_id, params \\ %{}) do
    entity_type = Map.get(params, "entity_type", "CONTRACT")
    rules = Map.get(params, "rules")

    result =
      case String.upcase(entity_type) do
        "CONTRACT" -> ETLOperations.transform_contracts(session_id, rules)
        "CUSTOMER" -> ETLOperations.transform_customers(session_id, rules)
        _ -> {:error, :validation_failed, ["unsupported entity_type: #{entity_type}"]}
      end

    with {:ok, count} <- result,
         {:ok, status} <- ETLOperations.get_session_status(session_id) do
      {:ok, Map.put(status, :transformed_count, count)}
    end
  end

  @doc """
  Validate staging data.
  """
  @spec validate(tenant_context(), String.t()) :: {:ok, map()} | {:error, term()}
  def validate(%{tenant_id: _tenant_id}, session_id) do
    with {:ok, issues} <- ETLOperations.validate_staging_data(session_id),
         {:ok, status} <- ETLOperations.get_session_status(session_id) do
      {:ok, %{
        session: status,
        validation_issues: issues,
        is_valid: Enum.empty?(issues)
      }}
    end
  end

  @doc """
  Promote staging data to production tables.
  """
  @spec promote(tenant_context(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def promote(%{tenant_id: _tenant_id, user: user}, session_id, params \\ %{}) do
    entity_type = Map.get(params, "entity_type", "CONTRACT")

    result =
      case String.upcase(entity_type) do
        "CONTRACT" -> ETLOperations.promote_contracts(session_id, user)
        "CUSTOMER" -> ETLOperations.promote_customers(session_id, user)
        _ -> {:error, :validation_failed, ["unsupported entity_type: #{entity_type}"]}
      end

    with {:ok, count} <- result,
         {:ok, status} <- ETLOperations.get_session_status(session_id) do
      {:ok, Map.put(status, :promoted_count, count)}
    end
  end

  @doc """
  Rollback/cancel a staging session.
  """
  @spec rollback(tenant_context(), String.t()) :: {:ok, map()} | {:error, term()}
  def rollback(%{tenant_id: _tenant_id}, session_id) do
    with :ok <- ETLOperations.rollback_session(session_id),
         {:ok, status} <- ETLOperations.get_session_status(session_id) do
      {:ok, status}
    end
  end

  @doc """
  Cleanup old sessions (admin operation).
  """
  @spec cleanup(tenant_context(), non_neg_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def cleanup(%{tenant_id: _tenant_id}, retention_days \\ 30) do
    ETLOperations.cleanup_old_sessions(retention_days)
  end
end
