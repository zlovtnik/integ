defmodule GprintEx.Integration.Translators.ContractTranslator do
  @moduledoc """
  Message Translator for Contract domain objects.

  Converts between external data formats and internal Contract domain structs.
  Supports multiple source formats (JSON, XML, CSV, legacy systems).

  ## Example

      # External JSON to domain
      {:ok, contract} = ContractTranslator.from_external(json_payload, :salesforce)

      # Domain to external format
      {:ok, json} = ContractTranslator.to_external(contract, :api_response)
  """

  alias GprintEx.Domain.Contract
  alias GprintEx.Result

  @type source_format :: :json | :xml | :csv | :salesforce | :legacy | :staging
  @type target_format :: :json | :api_response | :oracle | :staging | :export

  @doc """
  Translate external data to Contract domain struct.
  """
  @spec from_external(map(), source_format()) ::
          {:ok, Contract.t()} | {:error, :validation_failed, [String.t()]}
  def from_external(data, format) do
    data
    |> normalize_keys()
    |> apply_source_mapping(format)
    |> apply_transformations(format)
    |> Contract.new()
  end

  @doc """
  Translate Contract domain struct to external format.
  """
  @spec to_external(Contract.t(), target_format()) :: {:ok, map()} | {:error, term()}
  def to_external(%Contract{} = contract, format) do
    contract
    |> Contract.to_response()
    |> apply_target_mapping(format)
    |> Result.ok()
  end

  @doc """
  Translate a list of contracts.
  """
  @spec translate_batch([map()], source_format()) ::
          {:ok, [Contract.t()]} | {:error, [map()]}
  def translate_batch(items, format) when is_list(items) do
    results =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        case from_external(item, format) do
          {:ok, contract} -> {:ok, contract}
          {:error, _, errors} -> {:error, %{index: idx, errors: errors}}
        end
      end)

    {successes, failures} = Enum.split_with(results, &match?({:ok, _}, &1))

    if failures == [] do
      {:ok, Enum.map(successes, fn {:ok, c} -> c end)}
    else
      {:error, Enum.map(failures, fn {:error, e} -> e end)}
    end
  end

  @doc """
  Translate from Oracle row to domain.
  """
  @spec from_row(map()) :: {:ok, Contract.t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    Contract.from_row(row)
  end

  @doc """
  Translate from staging row to domain.
  """
  @spec from_staging(map()) :: {:ok, Contract.t()} | {:error, :validation_failed, [String.t()]}
  def from_staging(row) do
    # Staging rows have transformed_data as JSON
    case row[:transformed_data] do
      nil ->
        from_external(row[:raw_data], :staging)

      data when is_binary(data) ->
        case Jason.decode(data) do
          {:ok, decoded} -> from_external(decoded, :staging)
          {:error, reason} -> {:error, :validation_failed, ["Failed to decode transformed_data JSON: #{inspect(reason)}"]}
        end

      data when is_map(data) ->
        from_external(data, :staging)
    end
  end

  @doc """
  Get field mapping for a source format.
  """
  @spec field_mapping(source_format()) :: map()
  def field_mapping(:salesforce) do
    %{
      "ContractNumber" => :contract_number,
      "ContractName" => :contract_name,
      "Account.Id" => :customer_id,
      "StartDate" => :start_date,
      "EndDate" => :end_date,
      "ContractTerm" => :term_months,
      "TotalValue" => :total_value,
      "Status" => :status,
      "BillingStreet" => :billing_address,
      "PaymentTerms" => :payment_terms
    }
  end

  def field_mapping(:legacy) do
    %{
      "CONTR_NO" => :contract_number,
      "CONTR_NM" => :contract_name,
      "CUST_ID" => :customer_id,
      "DT_START" => :start_date,
      "DT_END" => :end_date,
      "MONTHS" => :term_months,
      "AMT_TOTAL" => :total_value,
      "STS_CD" => :status
    }
  end

  def field_mapping(:json) do
    # Standard JSON uses snake_case matching domain
    %{}
  end

  def field_mapping(_), do: %{}

  # Private functions

  defp normalize_keys(data) when is_map(data) do
    data
    |> Enum.map(fn {k, v} -> {normalize_key(k), v} end)
    |> Map.new()
  end

  defp normalize_key(key) when is_atom(key), do: key

  defp normalize_key(key) when is_binary(key) do
    normalized =
      key
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_]/, "_")

    try do
      String.to_existing_atom(normalized)
    rescue
      ArgumentError -> normalized
    end
  end

  defp apply_source_mapping(data, format) do
    mapping = field_mapping(format)

    if map_size(mapping) == 0 do
      data
    else
      Enum.reduce(mapping, %{}, fn {source_key, target_key}, acc ->
        value = get_nested_value(data, source_key)

        if value != nil do
          Map.put(acc, target_key, value)
        else
          acc
        end
      end)
      |> merge_unmapped_fields(data, mapping)
    end
  end

  defp get_nested_value(data, key) when is_binary(key) do
    if String.contains?(key, ".") do
      keys = String.split(key, ".")
      get_in(data, keys)
    else
      Map.get(data, key) || safe_atom_get(data, key)
    end
  end

  defp get_nested_value(data, key) do
    Map.get(data, key)
  end

  defp safe_atom_get(data, key) when is_binary(key) do
    try do
      atom_key = String.to_existing_atom(key)
      Map.get(data, atom_key)
    rescue
      ArgumentError -> nil
    end
  end

  defp merge_unmapped_fields(mapped, original, mapping) do
    mapped_source_keys = Map.keys(mapping) |> MapSet.new()

    unmapped =
      Enum.reject(original, fn {k, _v} ->
        MapSet.member?(mapped_source_keys, to_string(k)) or
          MapSet.member?(mapped_source_keys, k)
      end)
      |> Map.new()

    Map.merge(unmapped, mapped)
  end

  defp apply_transformations(data, format) do
    data
    |> transform_dates(format)
    |> transform_amounts(format)
    |> transform_status(format)
    |> add_metadata(format)
  end

  defp transform_dates(data, :salesforce) do
    Enum.reduce([:start_date, :end_date], data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        date_str -> Map.put(acc, key, parse_salesforce_date(date_str))
      end
    end)
  end

  defp transform_dates(data, :legacy) do
    Enum.reduce([:start_date, :end_date], data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        date_str -> Map.put(acc, key, parse_legacy_date(date_str))
      end
    end)
  end

  defp transform_dates(data, _), do: data

  defp parse_salesforce_date(date_str) when is_binary(date_str) do
    case Date.from_iso8601(date_str) do
      {:ok, date} -> date
      _ -> date_str
    end
  end

  defp parse_salesforce_date(date), do: date

  defp parse_legacy_date(date_str) when is_binary(date_str) do
    # Legacy format: YYYYMMDD
    case Regex.run(~r/^(\d{4})(\d{2})(\d{2})$/, date_str) do
      [_, y, m, d] ->
        case Date.new(String.to_integer(y), String.to_integer(m), String.to_integer(d)) do
          {:ok, date} -> date
          {:error, _} -> date_str
        end

      _ ->
        date_str
    end
  end

  defp parse_legacy_date(date), do: date

  defp transform_amounts(data, _format) do
    Enum.reduce([:total_value, :monthly_value], data, fn key, acc ->
      case Map.get(acc, key) do
        nil -> acc
        value when is_binary(value) -> Map.put(acc, key, parse_decimal(value))
        value -> Map.put(acc, key, value)
      end
    end)
  end

  defp parse_decimal(str) when is_binary(str) do
    str
    |> String.replace(",", "")
    |> String.replace("$", "")
    |> Decimal.new()
  rescue
    _ -> str
  end

  defp transform_status(data, :salesforce) do
    status_mapping = %{
      "Activated" => :active,
      "In Progress" => :pending,
      "Draft" => :draft,
      "Expired" => :expired,
      "Terminated" => :terminated
    }

    case Map.get(data, :status) do
      nil -> data
      status -> Map.put(data, :status, Map.get(status_mapping, status, status))
    end
  end

  defp transform_status(data, :legacy) do
    status_mapping = %{
      "A" => :active,
      "P" => :pending,
      "D" => :draft,
      "E" => :expired,
      "T" => :terminated,
      "S" => :suspended
    }

    case Map.get(data, :status) do
      nil -> data
      status -> Map.put(data, :status, Map.get(status_mapping, status, status))
    end
  end

  defp transform_status(data, _), do: data

  defp add_metadata(data, format) do
    Map.put(data, :source_format, format)
  end

  defp apply_target_mapping(data, :api_response) do
    data
    |> Map.drop([:source_format])
    |> convert_dates_to_iso8601()
    |> convert_decimals_to_string()
  end

  defp apply_target_mapping(data, :oracle) do
    # Convert to format expected by Oracle TYPE
    %{
      tenant_id: data[:tenant_id],
      id: data[:id],
      contract_number: data[:contract_number],
      contract_name: data[:contract_name],
      customer_id: data[:customer_id],
      start_date: format_oracle_date(data[:start_date]),
      end_date: format_oracle_date(data[:end_date]),
      status: to_string(data[:status]),
      total_value: data[:total_value],
      currency_code: data[:currency_code] || "BRL"
    }
  end

  defp apply_target_mapping(data, :export) do
    data
    |> convert_dates_to_iso8601()
    |> convert_decimals_to_string()
    |> Map.take([
      :contract_number,
      :contract_name,
      :start_date,
      :end_date,
      :status,
      :total_value
    ])
  end

  defp apply_target_mapping(data, _), do: data

  defp convert_dates_to_iso8601(data) do
    Enum.reduce(data, %{}, fn {k, v}, acc ->
      converted =
        case v do
          %Date{} = d -> Date.to_iso8601(d)
          %DateTime{} = dt -> DateTime.to_iso8601(dt)
          other -> other
        end

      Map.put(acc, k, converted)
    end)
  end

  defp convert_decimals_to_string(data) do
    Enum.reduce(data, %{}, fn {k, v}, acc ->
      converted =
        case v do
          %Decimal{} = d -> Decimal.to_string(d)
          other -> other
        end

      Map.put(acc, k, converted)
    end)
  end

  defp format_oracle_date(%Date{} = date) do
    Calendar.strftime(date, "%Y-%m-%d")
  end

  defp format_oracle_date(date), do: date
end
