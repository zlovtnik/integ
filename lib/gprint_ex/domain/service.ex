defmodule GprintEx.Domain.Service do
  @moduledoc """
  Service catalog domain entity.
  Represents services that can be added to contracts.
  """

  alias GprintEx.Domain.Types

  @type service_type :: :recurring | :one_time | :usage_based
  @type billing_unit :: :monthly | :yearly | :per_unit | :per_hour

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          tenant_id: Types.tenant_id(),
          service_code: String.t(),
          name: String.t(),
          description: String.t() | nil,
          service_type: service_type(),
          billing_unit: billing_unit(),
          default_price: Decimal.t(),
          tax_rate: Decimal.t() | nil,
          active: boolean(),
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:tenant_id, :service_code, :name, :default_price]
  defstruct [
    :id,
    :tenant_id,
    :service_code,
    :name,
    :description,
    :service_type,
    :billing_unit,
    :default_price,
    :tax_rate,
    :active,
    :created_at,
    :updated_at
  ]

  @doc "Create new service from params"
  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params) when is_map(params) do
    with {:ok, validated} <- validate(params) do
      {:ok, struct!(__MODULE__, validated)}
    end
  end

  @doc "Build from database row"
  @spec from_row(map()) :: {:ok, t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    {:ok,
     %__MODULE__{
       id: row[:id],
       tenant_id: row[:tenant_id],
       service_code: row[:service_code],
       name: row[:name],
       description: row[:description],
       service_type: parse_service_type(row[:service_type]),
       billing_unit: parse_billing_unit(row[:billing_unit]),
       default_price: parse_decimal(row[:default_price]) || Decimal.new(0),
       tax_rate: parse_decimal(row[:tax_rate]),
       active: row[:active] == 1 or row[:active] == true,
       created_at: row[:created_at],
       updated_at: row[:updated_at]
     }}
  end

  @doc "Convert to API response map"
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = service) do
    %{
      id: service.id,
      service_code: service.service_code,
      name: service.name,
      description: service.description,
      service_type: atom_to_upper(service.service_type),
      billing_unit: atom_to_upper(service.billing_unit),
      default_price: Decimal.to_string(service.default_price),
      tax_rate: service.tax_rate && Decimal.to_string(service.tax_rate),
      active: service.active,
      created_at: service.created_at,
      updated_at: service.updated_at
    }
  end

  # Private

  defp validate(params) do
    errors =
      []
      |> validate_required(params, :tenant_id)
      |> validate_required(params, :service_code)
      |> validate_required(params, :name)
      |> validate_required(params, :default_price)
      |> validate_non_negative(params, :default_price)

    case errors do
      [] -> {:ok, normalize(params)}
      errors -> {:error, :validation_failed, Enum.reverse(errors)}
    end
  end

  defp validate_required(errors, params, key) do
    value = Map.get(params, key) || Map.get(params, to_string(key))

    if value in [nil, ""] do
      ["#{key} is required" | errors]
    else
      errors
    end
  end

  defp validate_non_negative(errors, params, key) do
    value = Map.get(params, key) || Map.get(params, to_string(key))
    parsed = parse_decimal(value)

    cond do
      is_nil(value) -> errors
      is_nil(parsed) -> ["#{key} must be a valid number" | errors]
      Decimal.compare(parsed, Decimal.new(0)) in [:gt, :eq] -> errors
      true -> ["#{key} must be non-negative" | errors]
    end
  end

  defp normalize(params) do
    %{
      tenant_id: Map.get(params, :tenant_id) || Map.get(params, "tenant_id"),
      service_code: Map.get(params, :service_code) || Map.get(params, "service_code"),
      name: Map.get(params, :name) || Map.get(params, "name"),
      description: Map.get(params, :description) || Map.get(params, "description"),
      service_type:
        normalize_service_type(Map.get(params, :service_type) || Map.get(params, "service_type")),
      billing_unit:
        normalize_billing_unit(Map.get(params, :billing_unit) || Map.get(params, "billing_unit")),
      default_price:
        parse_decimal(Map.get(params, :default_price) || Map.get(params, "default_price")) ||
          Decimal.new(0),
      tax_rate: parse_decimal(Map.get(params, :tax_rate) || Map.get(params, "tax_rate")),
      active: Map.get(params, :active, Map.get(params, "active", true))
    }
  end

  defp normalize_service_type("RECURRING"), do: :recurring
  defp normalize_service_type("ONE_TIME"), do: :one_time
  defp normalize_service_type("USAGE_BASED"), do: :usage_based
  defp normalize_service_type(:recurring), do: :recurring
  defp normalize_service_type(:one_time), do: :one_time
  defp normalize_service_type(:usage_based), do: :usage_based
  defp normalize_service_type(_), do: :recurring

  defp parse_service_type("RECURRING"), do: :recurring
  defp parse_service_type("ONE_TIME"), do: :one_time
  defp parse_service_type("USAGE_BASED"), do: :usage_based
  defp parse_service_type(nil), do: :recurring
  defp parse_service_type(other) when other in [:recurring, :one_time, :usage_based], do: other
  defp parse_service_type(_), do: :recurring

  defp normalize_billing_unit("MONTHLY"), do: :monthly
  defp normalize_billing_unit("YEARLY"), do: :yearly
  defp normalize_billing_unit("PER_UNIT"), do: :per_unit
  defp normalize_billing_unit("PER_HOUR"), do: :per_hour
  defp normalize_billing_unit(:monthly), do: :monthly
  defp normalize_billing_unit(:yearly), do: :yearly
  defp normalize_billing_unit(:per_unit), do: :per_unit
  defp normalize_billing_unit(:per_hour), do: :per_hour
  defp normalize_billing_unit(_), do: :monthly

  @allowed_billing_units [:monthly, :yearly, :per_unit, :per_hour]

  defp parse_billing_unit("MONTHLY"), do: :monthly
  defp parse_billing_unit("YEARLY"), do: :yearly
  defp parse_billing_unit("PER_UNIT"), do: :per_unit
  defp parse_billing_unit("PER_HOUR"), do: :per_hour
  defp parse_billing_unit(nil), do: :monthly

  defp parse_billing_unit(other) when is_atom(other) do
    if other in @allowed_billing_units, do: other, else: :monthly
  end

  defp parse_billing_unit(_), do: :monthly

  defp parse_decimal(nil), do: nil
  defp parse_decimal(%Decimal{} = d), do: d
  defp parse_decimal(n) when is_integer(n), do: Decimal.new(n)
  defp parse_decimal(n) when is_float(n), do: Decimal.from_float(n)

  defp parse_decimal(s) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, ""} -> decimal
      _ -> nil
    end
  end

  defp parse_decimal(_), do: nil

  defp atom_to_upper(nil), do: nil
  defp atom_to_upper(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp atom_to_upper(other), do: other
end
