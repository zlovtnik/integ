defmodule GprintEx.ETL.Pipeline do
  @moduledoc """
  ETL Pipeline orchestrator.

  Manages the execution of Extract-Transform-Load pipelines for data integration.
  Coordinates extractors, transformers, and loaders while maintaining pipeline
  state and error handling.

  ## Features
  - Declarative pipeline definition
  - Step-by-step execution with checkpoints
  - Error recovery and retry logic
  - Progress tracking and telemetry
  - Session-based transaction management via PL/SQL

  ## Example

      pipeline = Pipeline.new("contract_import")
      |> Pipeline.add_extractor(CSVExtractor, file: "contracts.csv")
      |> Pipeline.add_transformer(ContractTransformer, validation: :strict)
      |> Pipeline.add_loader(OracleLoader, table: :contracts)

      {:ok, result} = Pipeline.run(pipeline, context)
  """

  require Logger

  alias GprintEx.Result

  @type step :: %{
          name: String.t(),
          type: :extract | :transform | :load | :validate,
          module: module(),
          opts: keyword(),
          status: :pending | :running | :completed | :failed | :skipped,
          result: term(),
          duration_ms: non_neg_integer()
        }

  @type t :: %__MODULE__{
          name: String.t(),
          session_id: String.t() | nil,
          tenant_id: String.t() | nil,
          steps: [step()],
          status: :pending | :running | :completed | :failed | :rolled_back,
          current_step: non_neg_integer(),
          data: term(),
          errors: [term()],
          metadata: map(),
          started_at: DateTime.t() | nil,
          completed_at: DateTime.t() | nil
        }

  defstruct [
    :name,
    :session_id,
    :tenant_id,
    steps: [],
    status: :pending,
    current_step: 0,
    data: nil,
    errors: [],
    metadata: %{},
    started_at: nil,
    completed_at: nil
  ]

  @doc """
  Create a new pipeline.
  """
  @spec new(String.t(), keyword()) :: t()
  def new(name, opts \\ []) do
    %__MODULE__{
      name: name,
      tenant_id: Keyword.get(opts, :tenant_id),
      metadata: Keyword.get(opts, :metadata, %{})
    }
  end

  @doc """
  Add an extraction step.
  """
  @spec add_extractor(t(), module(), keyword()) :: t()
  def add_extractor(pipeline, module, opts \\ []) do
    add_step(pipeline, :extract, module, opts)
  end

  @doc """
  Add a transformation step.
  """
  @spec add_transformer(t(), module(), keyword()) :: t()
  def add_transformer(pipeline, module, opts \\ []) do
    add_step(pipeline, :transform, module, opts)
  end

  @doc """
  Add a validation step.
  """
  @spec add_validator(t(), module(), keyword()) :: t()
  def add_validator(pipeline, module, opts \\ []) do
    add_step(pipeline, :validate, module, opts)
  end

  @doc """
  Add a loading step.
  """
  @spec add_loader(t(), module(), keyword()) :: t()
  def add_loader(pipeline, module, opts \\ []) do
    add_step(pipeline, :load, module, opts)
  end

  @doc """
  Add a custom step.
  """
  @spec add_step(t(), atom(), module(), keyword()) :: t() | {:error, :unsupported_step_type}
  def add_step(pipeline, type, module, opts) when type in [:extract, :transform, :validate, :load] do
    step = %{
      name: Keyword.get(opts, :name, step_name(type, module)),
      type: type,
      module: module,
      opts: opts,
      status: :pending,
      result: nil,
      duration_ms: 0
    }

    %{pipeline | steps: pipeline.steps ++ [step]}
  end

  def add_step(_pipeline, _type, _module, _opts) do
    {:error, :unsupported_step_type}
  end

  @doc """
  Run the pipeline.
  """
  @spec run(t(), map()) :: {:ok, t()} | {:error, t()}
  def run(pipeline, context \\ %{}) do
    pipeline = %{pipeline |
      status: :running,
      started_at: DateTime.utc_now(),
      tenant_id: context[:tenant_id] || pipeline.tenant_id
    }

    emit_pipeline_start(pipeline)

    case create_session(pipeline) do
      {:ok, session_id} ->
        pipeline = %{pipeline | session_id: session_id}
        execute_steps(pipeline, context)

      {:error, reason} ->
        pipeline = %{pipeline | status: :failed, errors: [reason]}
        emit_pipeline_failure(pipeline, reason)
        {:error, pipeline}
    end
  end

  @doc """
  Run pipeline with retry on failure.
  """
  @spec run_with_retry(t(), map(), keyword()) :: {:ok, t()} | {:error, t()}
  def run_with_retry(pipeline, context, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, 3)
    retry_delay = Keyword.get(opts, :retry_delay, 1000)

    do_run_with_retry(pipeline, context, max_retries, retry_delay, 0)
  end

  @doc """
  Resume a failed pipeline from the last successful step.
  """
  @spec resume(t(), map()) :: {:ok, t()} | {:error, t()} | {:error, :invalid_status, t()}
  def resume(%{status: :failed} = pipeline, context) do
    # Find the first failed step
    failed_idx = Enum.find_index(pipeline.steps, &(&1.status == :failed))

    if failed_idx do
      # Reset failed and subsequent steps
      updated_steps =
        pipeline.steps
        |> Enum.with_index()
        |> Enum.map(fn {step, idx} ->
          if idx >= failed_idx do
            %{step | status: :pending, result: nil}
          else
            step
          end
        end)

      pipeline = %{pipeline | steps: updated_steps, status: :running, current_step: failed_idx}
      execute_steps(pipeline, context)
    else
      {:error, pipeline}
    end
  end

  def resume(pipeline, _context) do
    {:error, :invalid_status, pipeline}
  end

  @doc """
  Rollback the pipeline.
  """
  @spec rollback(t()) :: {:ok, t()} | {:error, t()}
  def rollback(%{session_id: nil} = pipeline) do
    {:ok, %{pipeline | status: :rolled_back}}
  end

  def rollback(pipeline) do
    case rollback_session(pipeline.session_id) do
      :ok ->
        {:ok, %{pipeline | status: :rolled_back}}

      {:error, _reason} ->
        {:error, %{pipeline | status: :rollback_failed}}
    end
  end

  @doc """
  Get pipeline progress.
  """
  @spec progress(t()) :: map()
  def progress(pipeline) do
    total = length(pipeline.steps)
    completed = Enum.count(pipeline.steps, &(&1.status == :completed))
    failed = Enum.count(pipeline.steps, &(&1.status == :failed))

    %{
      total_steps: total,
      completed_steps: completed,
      failed_steps: failed,
      current_step: pipeline.current_step,
      percentage: if(total > 0, do: completed / total * 100, else: 0),
      status: pipeline.status,
      elapsed_ms: elapsed_time(pipeline)
    }
  end

  @doc """
  Get detailed step status.
  """
  @spec step_status(t()) :: [map()]
  def step_status(pipeline) do
    Enum.map(pipeline.steps, fn step ->
      %{
        name: step.name,
        type: step.type,
        status: step.status,
        duration_ms: step.duration_ms
      }
    end)
  end

  # Private functions

  defp step_name(type, module) do
    module_name = module |> Module.split() |> List.last()
    "#{type}_#{module_name}"
  end

  defp execute_steps(pipeline, context) do
    result =
      Enum.reduce_while(
        Enum.with_index(pipeline.steps),
        pipeline,
        fn {step, idx}, acc ->
          if step.status == :completed do
            # Skip already completed steps (for resume)
            {:cont, acc}
          else
            acc = %{acc | current_step: idx}

            case execute_step(step, acc.data, context) do
              {:ok, data, updated_step} ->
                updated_steps = List.replace_at(acc.steps, idx, updated_step)
                acc = %{acc | steps: updated_steps, data: data}
                {:cont, acc}

              {:error, reason, updated_step} ->
                updated_steps = List.replace_at(acc.steps, idx, updated_step)
                acc = %{acc | steps: updated_steps, errors: [reason | acc.errors], status: :failed}
                {:halt, acc}
            end
          end
        end
      )

    finalize_pipeline(result)
  end

  defp execute_step(step, input_data, context) do
    Logger.debug("Executing step: #{step.name}")
    emit_step_start(step)

    start_time = System.monotonic_time(:millisecond)

    result =
      try do
        apply_step(step, input_data, context)
      rescue
        e ->
          {:error, Exception.message(e)}
      catch
        :exit, reason ->
          {:error, {:exit, reason}}
      end

    duration = System.monotonic_time(:millisecond) - start_time

    case result do
      {:ok, data} ->
        updated_step = %{step | status: :completed, result: data, duration_ms: duration}
        emit_step_complete(updated_step)
        {:ok, data, updated_step}

      {:error, reason} ->
        updated_step = %{step | status: :failed, result: reason, duration_ms: duration}
        emit_step_failure(updated_step, reason)
        {:error, reason, updated_step}
    end
  end

  defp apply_step(%{type: :extract, module: mod, opts: opts}, _input, context) do
    mod.extract(opts, context)
  end

  defp apply_step(%{type: :transform, module: mod, opts: opts}, input, context) do
    mod.transform(input, opts, context)
  end

  defp apply_step(%{type: :validate, module: mod, opts: opts}, input, context) do
    case mod.validate(input, opts, context) do
      {:ok, validated} -> {:ok, validated}
      {:ok, validated, _warnings} -> {:ok, validated}
      {:error, _} = error -> error
    end
  end

  defp apply_step(%{type: :load, module: mod, opts: opts}, input, context) do
    mod.load(input, opts, context)
  end

  defp apply_step(%{type: type} = step, _input, _context) do
    {:error, {:unknown_step_type, type, step}}
  end

  defp finalize_pipeline(%{status: :failed} = pipeline) do
    pipeline = %{pipeline | completed_at: DateTime.utc_now()}

    # Attempt rollback on failure
    case rollback(pipeline) do
      {:ok, rolled_back} ->
        emit_pipeline_failure(rolled_back, pipeline.errors)
        {:error, rolled_back}

      {:error, _} ->
        emit_pipeline_failure(pipeline, pipeline.errors)
        {:error, pipeline}
    end
  end

  defp finalize_pipeline(pipeline) do
    pipeline = %{pipeline | status: :completed, completed_at: DateTime.utc_now()}

    # Commit the session
    case commit_session(pipeline.session_id) do
      :ok ->
        emit_pipeline_complete(pipeline)
        {:ok, pipeline}

      {:error, reason} ->
        pipeline = %{pipeline | status: :failed, errors: [reason | pipeline.errors]}
        emit_pipeline_failure(pipeline, reason)
        {:error, pipeline}
    end
  end

  defp do_run_with_retry(pipeline, context, max_retries, retry_delay, attempt) do
    case run(pipeline, context) do
      {:ok, _} = success ->
        success

      {:error, failed_pipeline} when attempt < max_retries ->
        Logger.warning("Pipeline #{pipeline.name} failed, retrying (#{attempt + 1}/#{max_retries})")
        Process.sleep(retry_delay * (attempt + 1))
        do_run_with_retry(pipeline, context, max_retries, retry_delay, attempt + 1)

      {:error, _} = failure ->
        failure
    end
  end

  defp create_session(pipeline) do
    # Call PL/SQL etl_pkg.create_staging_session
    # For now, return a mock session ID
    {:ok, "SESSION_#{:erlang.unique_integer([:positive])}"}
  end

  defp commit_session(nil), do: :ok

  defp commit_session(_session_id) do
    # Call PL/SQL to commit the session
    :ok
  end

  defp rollback_session(_session_id) do
    # Call PL/SQL etl_pkg.rollback_session
    :ok
  end

  defp elapsed_time(%{started_at: nil}), do: 0

  defp elapsed_time(%{started_at: started, completed_at: nil}) do
    DateTime.diff(DateTime.utc_now(), started, :millisecond)
  end

  defp elapsed_time(%{started_at: started, completed_at: completed}) do
    DateTime.diff(completed, started, :millisecond)
  end

  defp emit_pipeline_start(pipeline) do
    :telemetry.execute(
      [:gprint_ex, :etl, :pipeline, :start],
      %{count: 1},
      %{name: pipeline.name, tenant_id: pipeline.tenant_id}
    )
  end

  defp emit_pipeline_complete(pipeline) do
    :telemetry.execute(
      [:gprint_ex, :etl, :pipeline, :complete],
      %{duration_ms: elapsed_time(pipeline), steps: length(pipeline.steps)},
      %{name: pipeline.name, tenant_id: pipeline.tenant_id}
    )
  end

  defp emit_pipeline_failure(pipeline, reason) do
    :telemetry.execute(
      [:gprint_ex, :etl, :pipeline, :failure],
      %{duration_ms: elapsed_time(pipeline)},
      %{name: pipeline.name, tenant_id: pipeline.tenant_id, reason: reason}
    )
  end

  defp emit_step_start(step) do
    :telemetry.execute(
      [:gprint_ex, :etl, :step, :start],
      %{count: 1},
      %{name: step.name, type: step.type}
    )
  end

  defp emit_step_complete(step) do
    :telemetry.execute(
      [:gprint_ex, :etl, :step, :complete],
      %{duration_ms: step.duration_ms},
      %{name: step.name, type: step.type}
    )
  end

  defp emit_step_failure(step, reason) do
    :telemetry.execute(
      [:gprint_ex, :etl, :step, :failure],
      %{duration_ms: step.duration_ms},
      %{name: step.name, type: step.type, reason: reason}
    )
  end
end
