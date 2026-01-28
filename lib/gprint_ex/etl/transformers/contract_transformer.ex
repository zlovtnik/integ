defmodule GprintEx.ETL.Transformers.ContractTransformer do
  @moduledoc """
  ETL Transformer for Contract data.

  Applies business rules and data quality transformations to contract records.
  Integrates with ContractTranslator for format conversion and with
  PL/SQL etl_pkg for database-side transformations.

  ## Example

      opts = [validation: :strict, normalize_dates: true]
      {:ok, transformed} = ContractTransformer.transform(records, opts, context)
  """

  require Logger

  @behaviour GprintEx.ETL.Transformer

  alias GprintEx.Integration.Translators.ContractTranslator
  alias GprintEx.Domain.Contract

  @impl true
  @spec transform([map()], keyword(), map()) :: {:ok, [map()]} | {:error, term()}
  def transform(records, opts, context) when is_list(records) do
    validation_mode = Keyword.get(opts, :validation, :lenient)
    source_format = Keyword.get(opts, :source_format, :json)

    Logger.debug("Transforming #{length(records)} contract records")

    results =
      records
      |> Enum.with_index()
      |> Enum.map(fn {record, idx} ->
        transform_record(record, idx, source_format, validation_mode, context)
      end)

    case validation_mode do
      :strict ->
        # All records must succeed
        {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

        if Enum.empty?(failures) do
          transformed = Enum.map(successes, fn {:ok, r} -> r end)
          {:ok, transformed}
        else
          errors = Enum.map(failures, fn {:error, e} -> e end)
          {:error, {:transformation_failed, errors}}
        end

      :lenient ->
        # Return successes, log failures
        {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

        if !Enum.empty?(failures) do
          Logger.warning("#{length(failures)} contract records failed transformation")
        end

        transformed = Enum.map(successes, fn {:ok, r} -> r end)
        {:ok, transformed}

      :collect_errors ->
        # Return all with error indicators
        {:ok, results}
    end
  end

  @doc """
  Transform a single record.
  """
  @spec transform_record(map(), non_neg_integer(), atom(), atom(), map()) ::
          {:ok, map()} | {:error, map()}
  def transform_record(record, index, source_format, validation_mode, context) do
    tenant_id = context[:tenant_id]

    record
    |> Map.put(:tenant_id, tenant_id)
    |> normalize_fields()
    |> apply_business_rules(context)
    |> validate_record(validation_mode)
    |> case do
      {:ok, validated} ->
        {:ok, validated}

      {:error, errors} ->
        {:error, %{index: index, record: record, errors: errors}}
    end
  end

  @doc """
  Normalize contract fields.
  """
  @spec normalize_fields(map()) :: map()
  def normalize_fields(record) do
    record
    |> normalize_contract_number()
    |> normalize_dates()
    |> normalize_amounts()
    |> normalize_status()
    |> trim_strings()
  end

  @doc """
  Apply business rules to contract data.
  """
  @spec apply_business_rules(map(), map()) :: map()
  def apply_business_rules(record, _context) do
    record
    |> calculate_term_months()
    |> set_defaults()
    |> validate_date_range()
  end

  # Private functions

  defp normalize_contract_number(record) do
    case Map.get(record, :contract_number) do
      nil ->
        record

      number when is_binary(number) ->
        # Uppercase and remove invalid characters
        normalized =
          number
          |> String.upcase()
          |> String.replace(~r/[^A-Z0-9\-_]/, "")

        Map.put(record, :contract_number, normalized)

      _ ->
        record
    end
  end

  defp normalize_dates(record) do
    [:start_date, :end_date, :renewal_date]
    |> Enum.reduce(record, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        %Date{} = d -> Map.put(acc, key, d)
        value when is_binary(value) -> Map.put(acc, key, parse_date(value))
        _ -> acc
      end
    end)
  end

  defp parse_date(str) when is_binary(str) do
    cond do
      # ISO 8601: YYYY-MM-DD
      Regex.match?(~r/^\d{4}-\d{2}-\d{2}$/, str) ->
        Date.from_iso8601!(str)

      # DD/MM/YYYY (Brazilian format)
      Regex.match?(~r/^\d{2}\/\d{2}\/\d{4}$/, str) ->
        [d, m, y] = String.split(str, "/")
        Date.new!(String.to_integer(y), String.to_integer(m), String.to_integer(d))

      # YYYYMMDD
      Regex.match?(~r/^\d{8}$/, str) ->
        y = String.slice(str, 0, 4) |> String.to_integer()
        m = String.slice(str, 4, 2) |> String.to_integer()
        d = String.slice(str, 6, 2) |> String.to_integer()
        Date.new!(y, m, d)

      true ->
        str
    end
  rescue
    _ -> str
  end

  defp normalize_amounts(record) do
    [:total_value, :monthly_value]
    |> Enum.reduce(record, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        %Decimal{} = d -> Map.put(acc, key, d)
        value when is_integer(value) -> Map.put(acc, key, Decimal.new(value))
        value when is_float(value) -> Map.put(acc, key, Decimal.from_float(value))
        value when is_binary(value) -> Map.put(acc, key, parse_decimal(value))
        _ -> acc
      end
    end)
  end

  defp parse_decimal(str) when is_binary(str) do
    normalized =
      str
      |> String.replace("R$", "")
      |> String.replace("$", "")
      |> String.replace(" ", "")
      |> String.trim()

    cond do
      String.contains?(normalized, ".") and String.contains?(normalized, ",") ->
        # Detect format by last separator position
        last_dot = last_index(normalized, ".")
        last_comma = last_index(normalized, ",")

        if last_comma > last_dot do
          # Brazilian/European format: comma is decimal separator
          normalized
          |> String.replace(".", "")
          |> String.replace(",", ".")
        else
          # US format: dot is decimal separator
          String.replace(normalized, ",", "")
        end
      String.contains?(normalized, ",") ->
        # European format: replace comma with dot
        String.replace(normalized, ",", ".")
      true ->
        # US format or already normalized
        normalized
    end
    |> Decimal.new()
  rescue
    _ -> nil
  end

  defp last_index(string, char) do
    case :binary.matches(string, char) do
      [] -> -1
      matches -> matches |> List.last() |> elem(0)
    end
  end

  defp normalize_status(record) do
    case Map.get(record, :status) do
      nil -> record
      status when is_atom(status) -> record
      status when is_binary(status) ->
        normalized =
          status
          |> String.downcase()
          |> String.trim()
          |> case do
            "active" -> :active
            "ativo" -> :active
            "draft" -> :draft
            "rascunho" -> :draft
            "pending" -> :pending
            "pendente" -> :pending
            "expired" -> :expired
            "expirado" -> :expired
            "terminated" -> :terminated
            "cancelado" -> :terminated
            "suspended" -> :suspended
            "suspenso" -> :suspended
            other ->
              try do
                :erlang.binary_to_existing_atom(other, :utf8)
              rescue
                ArgumentError -> other
              end
          end
        Map.put(record, :status, normalized)
      _ -> record
    end
  end

  defp trim_strings(record) do
    Enum.reduce(record, %{}, fn {k, v}, acc ->
      trimmed = if is_binary(v), do: String.trim(v), else: v
      Map.put(acc, k, trimmed)
    end)
  end

  defp calculate_term_months(record) do
    case {Map.get(record, :start_date), Map.get(record, :end_date), Map.get(record, :term_months)} do
      {%Date{} = start, %Date{} = end_date, nil} ->
        months = Date.diff(end_date, start) |> div(30)
        Map.put(record, :term_months, months)

      _ ->
        record
    end
  end

  defp set_defaults(record) do
    record
    |> Map.put_new(:status, :draft)
    |> Map.put_new(:currency_code, "BRL")
    |> Map.put_new(:auto_renew, false)
  end

  defp validate_date_range(record) do
    case {Map.get(record, :start_date), Map.get(record, :end_date)} do
      {%Date{} = start, %Date{} = end_date} when start > end_date ->
        Map.put(record, :_validation_warning, "start_date is after end_date")

      _ ->
        record
    end
  end

  defp validate_record(record, :lenient) do
    {:ok, record}
  end

  defp validate_record(record, _mode) do
    errors = []

    errors =
      if is_nil(Map.get(record, :contract_number)) or Map.get(record, :contract_number) == "" do
        ["contract_number is required" | errors]
      else
        errors
      end

    errors =
      if is_nil(Map.get(record, :start_date)) do
        ["start_date is required" | errors]
      else
        errors
      end

    if Enum.empty?(errors) do
      {:ok, record}
    else
      {:error, errors}
    end
  end
end
