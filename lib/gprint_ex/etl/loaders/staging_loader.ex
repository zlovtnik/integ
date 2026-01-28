defmodule GprintEx.ETL.Loaders.StagingLoader do
  @moduledoc """
  ETL Loader for staging tables.

  Loads transformed data into Oracle staging tables via PL/SQL etl_pkg.
  Supports batch inserts, conflict handling, and validation tracking.

  ## Example

      opts = [entity_type: :contract, batch_size: 100]
      {:ok, result} = StagingLoader.load(records, opts, context)
  """

  require Logger

  @behaviour GprintEx.ETL.Loader

  alias GprintEx.Infrastructure.Repo.OracleConnection

  @default_batch_size 100

  @impl true
  @spec load([map()], keyword(), map()) :: {:ok, map()} | {:error, term()}
  def load(records, opts, context) when is_list(records) do
    session_id = Keyword.fetch!(opts, :session_id)
    entity_type = Keyword.get(opts, :entity_type, :contract)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    Logger.info("Loading #{length(records)} #{entity_type} records to staging")

    records
    |> Enum.chunk_every(batch_size)
    |> Enum.with_index()
    |> Enum.reduce_while({:ok, %{loaded: 0, failed: 0, errors: []}}, fn {batch, idx}, {:ok, acc} ->
      case load_batch(batch, session_id, entity_type, context) do
        {:ok, count} ->
          {:cont, {:ok, %{acc | loaded: acc.loaded + count}}}

        {:error, reason} ->
          Logger.error("Batch #{idx} failed: #{inspect(reason)}")
          new_acc = %{acc | failed: acc.failed + length(batch), errors: [reason | acc.errors]}

          if Keyword.get(opts, :fail_fast, true) do
            {:halt, {:error, new_acc}}
          else
            {:cont, {:ok, new_acc}}
          end
      end
    end)
    |> case do
      {:ok, result} ->
        Logger.info("Loaded #{result.loaded} records, #{result.failed} failed")
        {:ok, result}

      {:error, result} ->
        {:error, result}
    end
  end

  @doc """
  Load a single batch of records.
  """
  @spec load_batch([map()], String.t(), atom(), map()) :: {:ok, non_neg_integer()} | {:error, term()}
  def load_batch(batch, session_id, entity_type, context) do
    tenant_id = context[:tenant_id]
    user = context[:user] || "SYSTEM"

    # Prepare the data for PL/SQL
    rows = Enum.map(batch, fn record ->
      %{
        session_id: session_id,
        tenant_id: tenant_id,
        entity_type: to_string(entity_type),
        entity_id: Map.get(record, :id) || Map.get(record, :contract_number) || UUID.uuid4(),
        raw_data: Jason.encode!(record),
        transformed_data: nil,
        validation_status: "PENDING",
        created_by: user
      }
    end)

    # Call PL/SQL etl_pkg.load_to_staging
    case insert_staging_rows(rows) do
      {:ok, _} -> {:ok, length(batch)}
      {:error, _} = error -> error
    end
  end

  @doc """
  Load data directly to target table (bypass staging).
  """
  @spec load_direct([map()], keyword(), map()) :: {:ok, map()} | {:error, term()}
  def load_direct(records, opts, context) do
    table = Keyword.fetch!(opts, :table)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)

    Logger.info("Direct loading #{length(records)} records to #{table}")

    results =
      records
      |> Enum.chunk_every(batch_size)
      |> Enum.map(&insert_direct_batch(&1, table, context))

    successes = Enum.count(results, &match?({:ok, _}, &1))
    total_loaded = results |> Enum.filter(&match?({:ok, _}, &1)) |> Enum.map(fn {:ok, n} -> n end) |> Enum.sum()
    failed = Enum.filter(results, &match?({:error, _}, &1))

    if failed == [] do
      {:ok, %{batches: length(results), successful_batches: successes, loaded: total_loaded}}
    else
      failed_count = length(failed)
      error_list = Enum.map(failed, fn {:error, reason} -> reason end)
      {:error, %{batches: length(results), successful_batches: successes, failed_batches: failed_count, loaded: total_loaded, errors: error_list}}
    end
  end

  # Private functions

  defp insert_staging_rows(rows) do
    # This would call etl_pkg.load_to_staging
    # For now, simulate the insert
    sql = """
    INSERT INTO etl_staging (
      session_id, tenant_id, entity_type, entity_id,
      raw_data, transformed_data, validation_status, created_by
    ) VALUES (:1, :2, :3, :4, :5, :6, :7, :8)
    """

    OracleConnection.transaction(:gprint_pool, fn ->
      Enum.each(rows, fn row ->
        params = [
          row.session_id,
          row.tenant_id,
          row.entity_type,
          row.entity_id,
          row.raw_data,
          row.transformed_data,
          row.validation_status,
          row.created_by
        ]

        case OracleConnection.execute(:gprint_pool, sql, params) do
          {:ok, _} -> :ok
          {:error, reason} -> raise "Insert failed: #{inspect(reason)}"
        end
      end)

      {:ok, length(rows)}
    end)
  end

  defp insert_direct_batch(batch, table, context) do
    raise "insert_direct_batch/3 is not yet implemented"
  end
end
