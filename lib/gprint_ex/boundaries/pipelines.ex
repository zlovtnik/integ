defmodule GprintEx.Boundaries.Pipelines do
  @moduledoc """
  Boundary for ETL pipeline management.

  Provides high-level orchestration for running and monitoring ETL pipelines.
  """

  alias GprintEx.ETL.Pipeline
  alias GprintEx.ETL.Extractors.{FileExtractor, APIExtractor}
  alias GprintEx.ETL.Transformers.{ContractTransformer, CustomerTransformer}
  alias GprintEx.ETL.Loaders.StagingLoader

  @type tenant_context :: %{tenant_id: String.t(), user: String.t()}

  @doc """
  Run a predefined pipeline by name.
  """
  @spec run(tenant_context(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def run(%{tenant_id: tenant_id, user: user} = ctx, pipeline_name, params) do
    context = %{tenant_id: tenant_id, user: user, params: params}

    case build_pipeline(pipeline_name, params) do
      {:ok, pipeline} ->
        case Pipeline.run(pipeline, context) do
          {:ok, result} -> {:ok, pipeline_to_response(result)}
          {:error, result} -> {:error, pipeline_to_response(result)}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get status of a running or completed pipeline.
  """
  @spec get_status(tenant_context(), String.t()) :: {:ok, map()} | {:error, :not_found}
  def get_status(%{tenant_id: _tenant_id}, session_id) do
    case Pipeline.get_by_session(session_id) do
      {:ok, pipeline} -> {:ok, pipeline_to_response(pipeline)}
      error -> error
    end
  end

  @doc """
  List available pipeline templates.
  """
  @spec list_templates(tenant_context()) :: {:ok, [map()]}
  def list_templates(%{tenant_id: _tenant_id}) do
    templates = [
      %{
        name: "contract_import",
        description: "Import contracts from CSV/JSON file",
        required_params: ["source_file", "format"],
        optional_params: ["validation_mode", "transform_rules"]
      },
      %{
        name: "customer_import",
        description: "Import customers from CSV/JSON file",
        required_params: ["source_file", "format"],
        optional_params: ["validation_mode", "transform_rules"]
      },
      %{
        name: "api_sync",
        description: "Sync data from external API",
        required_params: ["api_endpoint", "entity_type"],
        optional_params: ["auth_headers", "pagination"]
      },
      %{
        name: "bulk_contract_update",
        description: "Bulk update existing contracts",
        required_params: ["records"],
        optional_params: ["update_mode", "validation_mode"]
      },
      %{
        name: "bulk_customer_update",
        description: "Bulk update existing customers",
        required_params: ["records"],
        optional_params: ["update_mode", "validation_mode"]
      }
    ]

    {:ok, templates}
  end

  @doc """
  Cancel a running pipeline.
  """
  @spec cancel(tenant_context(), String.t()) :: :ok | {:error, term()}
  def cancel(%{tenant_id: _tenant_id}, session_id) do
    Pipeline.cancel(session_id)
  end

  # Private helpers

  defp build_pipeline("contract_import", params) do
    pipeline =
      Pipeline.new("contract_import", tenant_id: params["tenant_id"])
      |> Pipeline.add_extractor(FileExtractor,
        file: params["source_file"],
        format: String.to_atom(params["format"] || "csv")
      )
      |> Pipeline.add_transformer(ContractTransformer,
        validation: String.to_atom(params["validation_mode"] || "strict"),
        rules: params["transform_rules"]
      )
      |> Pipeline.add_loader(StagingLoader, entity_type: :contract)

    {:ok, pipeline}
  end

  defp build_pipeline("customer_import", params) do
    pipeline =
      Pipeline.new("customer_import", tenant_id: params["tenant_id"])
      |> Pipeline.add_extractor(FileExtractor,
        file: params["source_file"],
        format: String.to_atom(params["format"] || "csv")
      )
      |> Pipeline.add_transformer(CustomerTransformer,
        validation: String.to_atom(params["validation_mode"] || "strict"),
        rules: params["transform_rules"]
      )
      |> Pipeline.add_loader(StagingLoader, entity_type: :customer)

    {:ok, pipeline}
  end

  defp build_pipeline("api_sync", params) do
    pipeline =
      Pipeline.new("api_sync", tenant_id: params["tenant_id"])
      |> Pipeline.add_extractor(APIExtractor,
        endpoint: params["api_endpoint"],
        headers: params["auth_headers"] || %{},
        pagination: params["pagination"]
      )
      |> add_transformer_for_entity(params["entity_type"], params)
      |> Pipeline.add_loader(StagingLoader,
        entity_type: String.to_atom(params["entity_type"])
      )

    {:ok, pipeline}
  end

  defp build_pipeline("bulk_contract_update", params) do
    pipeline =
      Pipeline.new("bulk_contract_update", tenant_id: params["tenant_id"])
      |> Pipeline.add_step(:extract, GprintEx.ETL.Extractors.MemoryExtractor,
        records: params["records"]
      )
      |> Pipeline.add_transformer(ContractTransformer,
        validation: String.to_atom(params["validation_mode"] || "strict"),
        mode: String.to_atom(params["update_mode"] || "upsert")
      )
      |> Pipeline.add_loader(StagingLoader, entity_type: :contract)

    {:ok, pipeline}
  end

  defp build_pipeline("bulk_customer_update", params) do
    pipeline =
      Pipeline.new("bulk_customer_update", tenant_id: params["tenant_id"])
      |> Pipeline.add_step(:extract, GprintEx.ETL.Extractors.MemoryExtractor,
        records: params["records"]
      )
      |> Pipeline.add_transformer(CustomerTransformer,
        validation: String.to_atom(params["validation_mode"] || "strict"),
        mode: String.to_atom(params["update_mode"] || "upsert")
      )
      |> Pipeline.add_loader(StagingLoader, entity_type: :customer)

    {:ok, pipeline}
  end

  defp build_pipeline(name, _params) do
    {:error, :validation_failed, ["unknown pipeline: #{name}"]}
  end

  defp add_transformer_for_entity(pipeline, "contract", params) do
    Pipeline.add_transformer(pipeline, ContractTransformer,
      validation: String.to_atom(params["validation_mode"] || "strict")
    )
  end

  defp add_transformer_for_entity(pipeline, "customer", params) do
    Pipeline.add_transformer(pipeline, CustomerTransformer,
      validation: String.to_atom(params["validation_mode"] || "strict")
    )
  end

  defp add_transformer_for_entity(pipeline, _entity_type, _params), do: pipeline

  defp pipeline_to_response(%Pipeline{} = pipeline) do
    %{
      name: pipeline.name,
      session_id: pipeline.session_id,
      tenant_id: pipeline.tenant_id,
      status: pipeline.status,
      current_step: pipeline.current_step,
      total_steps: length(pipeline.steps),
      steps: Enum.map(pipeline.steps, &step_to_response/1),
      errors: pipeline.errors,
      started_at: pipeline.started_at,
      completed_at: pipeline.completed_at
    }
  end

  defp step_to_response(step) do
    %{
      name: step.name,
      type: step.type,
      status: step.status,
      duration_ms: step.duration_ms
    }
  end
end
