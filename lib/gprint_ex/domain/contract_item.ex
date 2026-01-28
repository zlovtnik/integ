defmodule GprintEx.Domain.ContractItem do
  @moduledoc """
  Contract line item domain entity.
  Pure data structure with validation functions.
  """

  alias GprintEx.Domain.Types

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          tenant_id: Types.tenant_id(),
          contract_id: pos_integer(),
          line_number: pos_integer(),
          service_id: pos_integer() | nil,
          description: String.t(),
          quantity: Decimal.t(),
          unit_price: Decimal.t(),
          discount_pct: Decimal.t(),
          total_price: Decimal.t() | nil,
          notes: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  @enforce_keys [:tenant_id, :contract_id, :description, :quantity, :unit_price]
  defstruct [
    :id,
    :tenant_id,
    :contract_id,
    :line_number,
    :service_id,
    :description,
    :quantity,
    :unit_price,
    :discount_pct,
    :total_price,
    :notes,
    :created_at,
    :updated_at
  ]

  @doc "Create new contract item from params"
  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params) when is_map(params) do
    with {:ok, validated} <- validate(params) do
      item = struct!(__MODULE__, validated)
      {:ok, calculate_total(item)}
    end
  end

  @doc "Build from database row"
  @spec from_row(map()) :: {:ok, t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    {:ok,
     %__MODULE__{
       id: row[:id],
       tenant_id: row[:tenant_id],
       contract_id: row[:contract_id],
       line_number: row[:line_number],
       service_id: row[:service_id],
       description: row[:description],
       quantity: parse_decimal(row[:quantity]) || Decimal.new(1),
       unit_price: parse_decimal(row[:unit_price]) || Decimal.new(0),
       discount_pct: parse_decimal(row[:discount_pct]) || Decimal.new(0),
       total_price: parse_decimal(row[:total_price]),
       notes: row[:notes],
       created_at: row[:created_at],
       updated_at: row[:updated_at]
     }}
  end

  @doc "Calculate total price for item"
  @spec calculate_total(t()) :: t()
  def calculate_total(%__MODULE__{} = item) do
    qty = item.quantity || Decimal.new(1)
    price = item.unit_price || Decimal.new(0)
    discount = item.discount_pct || Decimal.new(0)

    discount_factor = Decimal.sub(Decimal.new(1), Decimal.div(discount, Decimal.new(100)))
    total = Decimal.mult(Decimal.mult(qty, price), discount_factor)

    %{item | total_price: total}
  end

  @doc "Convert to API response map"
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = item) do
    %{
      id: item.id,
      line_number: item.line_number,
      service_id: item.service_id,
      description: item.description,
      quantity: Decimal.to_string(item.quantity),
      unit_price: Decimal.to_string(item.unit_price),
      discount_pct: Decimal.to_string(item.discount_pct),
      total_price: item.total_price && Decimal.to_string(item.total_price),
      notes: item.notes
    }
  end

  # Private

  defp validate(params) do
    errors =
      []
      |> validate_required(params, :tenant_id)
      |> validate_required(params, :contract_id)
      |> validate_required(params, :description)
      |> validate_positive(params, :quantity)
      |> validate_non_negative(params, :unit_price)

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

  defp validate_positive(errors, params, key) do
    value = Map.get(params, key) || Map.get(params, to_string(key))
    parsed = parse_decimal(value)

    cond do
      is_nil(value) -> errors
      is_nil(parsed) -> ["#{key} must be a valid number" | errors]
      Decimal.compare(parsed, Decimal.new(0)) == :gt -> errors
      true -> ["#{key} must be positive" | errors]
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
      contract_id: Map.get(params, :contract_id) || Map.get(params, "contract_id"),
      line_number: Map.get(params, :line_number) || Map.get(params, "line_number"),
      service_id: Map.get(params, :service_id) || Map.get(params, "service_id"),
      description: Map.get(params, :description) || Map.get(params, "description"),
      quantity:
        parse_decimal(Map.get(params, :quantity) || Map.get(params, "quantity")) ||
          Decimal.new(1),
      unit_price:
        parse_decimal(Map.get(params, :unit_price) || Map.get(params, "unit_price")) ||
          Decimal.new(0),
      discount_pct:
        parse_decimal(Map.get(params, :discount_pct) || Map.get(params, "discount_pct")) ||
          Decimal.new(0),
      notes: Map.get(params, :notes) || Map.get(params, "notes")
    }
  end

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
end
