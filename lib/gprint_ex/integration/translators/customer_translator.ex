defmodule GprintEx.Integration.Translators.CustomerTranslator do
  @moduledoc """
  Message Translator for Customer domain objects.

  Converts between external data formats and internal Customer domain structs.
  Handles customer-specific transformations including tax ID normalization,
  address formatting, and contact information parsing.

  ## Example

      # External JSON to domain
      {:ok, customer} = CustomerTranslator.from_external(json_payload, :crm)

      # Domain to external format
      {:ok, json} = CustomerTranslator.to_external(customer, :api_response)
  """

  alias GprintEx.Domain.Customer
  alias GprintEx.Result

  @type source_format :: :json | :crm | :erp | :legacy | :staging | :spreadsheet
  @type target_format :: :json | :api_response | :oracle | :staging | :export

  @doc """
  Translate external data to Customer domain struct.
  """
  @spec from_external(map(), source_format()) ::
          {:ok, Customer.t()} | {:error, :validation_failed, [String.t()]}
  def from_external(data, format) do
    data
    |> normalize_keys()
    |> apply_source_mapping(format)
    |> apply_transformations(format)
    |> Customer.new()
  end

  @doc """
  Translate Customer domain struct to external format.
  """
  @spec to_external(Customer.t(), target_format()) :: {:ok, map()} | {:error, term()}
  def to_external(%Customer{} = customer, format) do
    customer
    |> Customer.to_response()
    |> apply_target_mapping(format)
    |> Result.ok()
  end

  @doc """
  Translate a list of customers.
  """
  @spec translate_batch([map()], source_format()) ::
          {:ok, [Customer.t()]} | {:error, [map()]}
  def translate_batch(items, format) when is_list(items) do
    results =
      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        case from_external(item, format) do
          {:ok, customer} -> {:ok, customer}
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
  @spec from_row(map()) :: {:ok, Customer.t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    Customer.from_row(row)
  end

  @doc """
  Translate from staging row to domain.
  """
  @spec from_staging(map()) :: {:ok, Customer.t()} | {:error, :validation_failed, [String.t()]}
  def from_staging(row) do
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
  def field_mapping(:crm) do
    %{
      "AccountNumber" => :customer_code,
      "AccountName" => :name,
      "BillingStreet" => :billing_street,
      "BillingCity" => :billing_city,
      "BillingState" => :billing_state,
      "BillingPostalCode" => :billing_postal_code,
      "BillingCountry" => :billing_country,
      "Phone" => :phone,
      "Email" => :email,
      "TaxId" => :tax_id,
      "CustomerType" => :customer_type,
      "Industry" => :industry,
      "Active" => :active
    }
  end

  def field_mapping(:erp) do
    %{
      "CUST_CODE" => :customer_code,
      "CUST_NAME" => :name,
      "ADDR_LINE1" => :billing_street,
      "ADDR_CITY" => :billing_city,
      "ADDR_STATE" => :billing_state,
      "ADDR_ZIP" => :billing_postal_code,
      "ADDR_COUNTRY" => :billing_country,
      "TEL_NO" => :phone,
      "EMAIL_ADDR" => :email,
      "TAX_REG_NO" => :tax_id,
      "CUST_TYPE" => :customer_type,
      "STATUS" => :status
    }
  end

  def field_mapping(:legacy) do
    %{
      "CD_CLIENTE" => :customer_code,
      "NM_CLIENTE" => :name,
      "DS_ENDERECO" => :billing_street,
      "NM_CIDADE" => :billing_city,
      "SG_ESTADO" => :billing_state,
      "NR_CEP" => :billing_postal_code,
      "NR_TELEFONE" => :phone,
      "DS_EMAIL" => :email,
      "NR_CNPJ" => :tax_id,
      "TP_PESSOA" => :customer_type
    }
  end

  def field_mapping(:spreadsheet) do
    %{
      "Código" => :customer_code,
      "Nome/Razão Social" => :name,
      "Endereço" => :billing_street,
      "Cidade" => :billing_city,
      "UF" => :billing_state,
      "CEP" => :billing_postal_code,
      "Telefone" => :phone,
      "E-mail" => :email,
      "CPF/CNPJ" => :tax_id,
      "Tipo" => :customer_type
    }
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
      mapped =
        Enum.reduce(mapping, %{}, fn {source_key, target_key}, acc ->
          value = get_field_value(data, source_key)

          if value != nil do
            Map.put(acc, target_key, value)
          else
            acc
          end
        end)

      merge_unmapped_fields(mapped, data, mapping)
    end
  end

  defp get_field_value(data, key) when is_binary(key) do
    Map.get(data, key) ||
      Map.get(data, String.downcase(key)) ||
      safe_atom_get(data, key |> String.downcase() |> String.replace(~r/[^a-z0-9_]/, "_"))
  end

  defp get_field_value(data, key) do
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
    mapped_source_keys =
      mapping
      |> Map.keys()
      |> Enum.flat_map(fn k -> [k, String.downcase(k)] end)
      |> MapSet.new()

    unmapped =
      Enum.reject(original, fn {k, _v} ->
        key_str = to_string(k)
        MapSet.member?(mapped_source_keys, key_str) or
          MapSet.member?(mapped_source_keys, String.downcase(key_str))
      end)
      |> Map.new()

    Map.merge(unmapped, mapped)
  end

  defp apply_transformations(data, format) do
    data
    |> normalize_tax_id(format)
    |> normalize_phone(format)
    |> normalize_email()
    |> transform_customer_type(format)
    |> build_address()
    |> add_metadata(format)
  end

  defp normalize_tax_id(data, _format) do
    case Map.get(data, :tax_id) do
      nil ->
        data

      tax_id when is_binary(tax_id) ->
        # Remove all non-digit characters
        cleaned = String.replace(tax_id, ~r/\D/, "")
        Map.put(data, :tax_id, cleaned)

      _ ->
        data
    end
  end

  defp normalize_phone(data, _format) do
    case Map.get(data, :phone) do
      nil ->
        data

      phone when is_binary(phone) ->
        # Keep only digits and format for Brazil
        cleaned = String.replace(phone, ~r/\D/, "")

        formatted =
          case String.length(cleaned) do
            11 ->
              # Mobile: (XX) XXXXX-XXXX
              "(" <> String.slice(cleaned, 0, 2) <> ") " <>
                String.slice(cleaned, 2, 5) <> "-" <> String.slice(cleaned, 7, 4)

            10 ->
              # Landline: (XX) XXXX-XXXX
              "(" <> String.slice(cleaned, 0, 2) <> ") " <>
                String.slice(cleaned, 2, 4) <> "-" <> String.slice(cleaned, 6, 4)

            _ ->
              cleaned
          end

        Map.put(data, :phone, formatted)

      _ ->
        data
    end
  end

  defp normalize_email(data) do
    case Map.get(data, :email) do
      nil ->
        data

      email when is_binary(email) ->
        Map.put(data, :email, String.downcase(String.trim(email)))

      _ ->
        data
    end
  end

  defp transform_customer_type(data, :legacy) do
    type_mapping = %{
      "F" => :individual,
      "J" => :company,
      "PF" => :individual,
      "PJ" => :company
    }

    case Map.get(data, :customer_type) do
      nil -> data
      type -> Map.put(data, :customer_type, Map.get(type_mapping, type, type))
    end
  end

  defp transform_customer_type(data, :crm) do
    type_mapping = %{
      "Individual" => :individual,
      "Business" => :company,
      "Person" => :individual,
      "Company" => :company,
      "Organization" => :company
    }

    case Map.get(data, :customer_type) do
      nil -> data
      type -> Map.put(data, :customer_type, Map.get(type_mapping, type, type))
    end
  end

  defp transform_customer_type(data, _), do: data

  defp build_address(data) do
    # Combine address parts into a full address if needed
    parts =
      [:billing_street, :billing_city, :billing_state, :billing_postal_code, :billing_country]
      |> Enum.map(&Map.get(data, &1))
      |> Enum.reject(&is_nil/1)

    if Enum.empty?(parts) do
      data
    else
      full_address = Enum.join(parts, ", ")
      Map.put(data, :full_address, full_address)
    end
  end

  defp add_metadata(data, format) do
    Map.put(data, :source_format, format)
  end

  defp apply_target_mapping(data, :api_response) do
    data
    |> Map.drop([:source_format, :full_address])
    |> format_for_json()
  end

  defp apply_target_mapping(data, :oracle) do
    %{
      tenant_id: data[:tenant_id],
      id: data[:id],
      customer_code: data[:customer_code],
      name: data[:name],
      tax_id: data[:tax_id],
      customer_type: to_string(data[:customer_type]),
      email: data[:email],
      phone: data[:phone],
      billing_address: data[:full_address] || data[:billing_street],
      active: if(data[:active] == true, do: 1, else: 0)
    }
  end

  defp apply_target_mapping(data, :export) do
    %{
      customer_code: data[:customer_code],
      name: data[:name],
      tax_id: format_tax_id_for_export(data[:tax_id]),
      email: data[:email],
      phone: data[:phone],
      address: data[:full_address] || data[:billing_street],
      city: data[:billing_city],
      state: data[:billing_state],
      postal_code: data[:billing_postal_code],
      active: data[:active]
    }
  end

  defp apply_target_mapping(data, _), do: data

  defp format_for_json(data) do
    Enum.reduce(data, %{}, fn {k, v}, acc ->
      Map.put(acc, k, format_value_for_json(v))
    end)
  end

  defp format_value_for_json(%Date{} = date), do: Date.to_iso8601(date)
  defp format_value_for_json(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_value_for_json(%Decimal{} = d), do: Decimal.to_string(d)
  defp format_value_for_json(value), do: value

  defp format_tax_id_for_export(nil), do: nil

  defp format_tax_id_for_export(tax_id) when is_binary(tax_id) do
    cleaned = String.replace(tax_id, ~r/\D/, "")

    case String.length(cleaned) do
      11 ->
        # CPF: XXX.XXX.XXX-XX
        String.slice(cleaned, 0, 3) <> "." <>
          String.slice(cleaned, 3, 3) <> "." <>
          String.slice(cleaned, 6, 3) <> "-" <>
          String.slice(cleaned, 9, 2)

      14 ->
        # CNPJ: XX.XXX.XXX/XXXX-XX
        String.slice(cleaned, 0, 2) <> "." <>
          String.slice(cleaned, 2, 3) <> "." <>
          String.slice(cleaned, 5, 3) <> "/" <>
          String.slice(cleaned, 8, 4) <> "-" <>
          String.slice(cleaned, 12, 2)

      _ ->
        cleaned
    end
  end
end
