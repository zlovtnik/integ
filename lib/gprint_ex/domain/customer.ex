defmodule GprintEx.Domain.Customer do
  @moduledoc """
  Customer domain entity.
  Pure data structure with validation functions.
  """

  alias GprintEx.Domain.Types

  @type customer_type :: :individual | :company
  @type status :: :active | :inactive

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          tenant_id: Types.tenant_id(),
          customer_code: String.t(),
          customer_type: customer_type(),
          name: String.t(),
          trade_name: String.t() | nil,
          tax_id: String.t() | nil,
          email: String.t() | nil,
          phone: String.t() | nil,
          address: Types.address() | nil,
          active: boolean(),
          notes: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          created_by: String.t() | nil,
          updated_by: String.t() | nil
        }

  @enforce_keys [:tenant_id, :customer_code, :name]
  defstruct [
    :id,
    :tenant_id,
    :customer_code,
    :customer_type,
    :name,
    :trade_name,
    :tax_id,
    :email,
    :phone,
    :address,
    :active,
    :notes,
    :created_at,
    :updated_at,
    :created_by,
    :updated_by
  ]

  @doc "Create a new customer from validated params"
  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params) when is_map(params) do
    with {:ok, validated} <- validate(params) do
      {:ok, struct!(__MODULE__, validated)}
    end
  end

  @doc "Build from database row"
  @spec from_row(map()) :: {:ok, t()} | {:error, term()}
  def from_row(row) when is_map(row) do
    # Validate required fields
    with {:ok, tenant_id} <- fetch_required(row, :tenant_id),
         {:ok, customer_code} <- fetch_required(row, :customer_code),
         {:ok, name} <- fetch_required(row, :name) do
      customer_type_result = parse_customer_type(row[:customer_type])
      address_result = Types.build_address(row)

      {:ok,
       %__MODULE__{
         id: row[:id],
         tenant_id: tenant_id,
         customer_code: customer_code,
         customer_type: customer_type_result,
         name: name,
         trade_name: row[:trade_name],
         tax_id: row[:tax_id],
         email: row[:email],
         phone: row[:phone],
         address: address_result,
         active: row[:active] == 1 or row[:active] == true,
         notes: row[:notes],
         created_at: row[:created_at],
         updated_at: row[:updated_at],
         created_by: row[:created_by],
         updated_by: row[:updated_by]
       }}
    end
  end

  defp fetch_required(row, key) do
    case row[key] do
      nil -> {:error, {:missing_field, key}}
      "" -> {:error, {:empty_field, key}}
      value -> {:ok, value}
    end
  end

  @doc "Validate customer params"
  @spec validate(map()) :: {:ok, map()} | {:error, :validation_failed, [String.t()]}
  def validate(params) do
    errors =
      []
      |> validate_required(params, :tenant_id)
      |> validate_required(params, :customer_code)
      |> validate_required(params, :name)
      |> validate_email(params)
      |> validate_tax_id(params)

    case errors do
      [] ->
        {:ok, normalize_params(params)}

      errors ->
        {:error, :validation_failed, Enum.reverse(errors)}
    end
  end

  # Pure validation functions
  defp validate_required(errors, params, key) do
    case Map.get(params, key) || Map.get(params, to_string(key)) do
      nil -> ["#{key} is required" | errors]
      "" -> ["#{key} is required" | errors]
      _ -> errors
    end
  end

  defp validate_email(errors, params) do
    email = Map.get(params, :email) || Map.get(params, "email")

    if is_binary(email) and email != "" do
      case validate_email_format(email) do
        :ok -> errors
        {:error, _reason} -> ["invalid email format" | errors]
      end
    else
      errors
    end
  end

  defp validate_email_format(email) do
    if Code.ensure_loaded?(EmailChecker) do
      if EmailChecker.valid?(email), do: :ok, else: {:error, :invalid_format}
    else
      # Fallback: comprehensive RFC-5322 based regex
      rfc5322_regex =
        ~r/^(?:[a-z0-9!#$%&'*+\/=?^_`{|}~-]+(?:\.[a-z0-9!#$%&'*+\/=?^_`{|}~-]+)*|"(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21\x23-\x5b\x5d-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])*")@(?:(?:[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+[a-z0-9](?:[a-z0-9-]*[a-z0-9])?|\[(?:(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(?:25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?|[a-z0-9-]*[a-z0-9]:(?:[\x01-\x08\x0b\x0c\x0e-\x1f\x21-\x5a\x53-\x7f]|\\[\x01-\x09\x0b\x0c\x0e-\x7f])+)\])$/i

      if Regex.match?(rfc5322_regex, email), do: :ok, else: {:error, :invalid_format}
    end
  end

  defp validate_tax_id(errors, params) do
    tax_id = Map.get(params, :tax_id) || Map.get(params, "tax_id")
    customer_type = Map.get(params, :customer_type) || Map.get(params, "customer_type")

    cond do
      is_nil(tax_id) or tax_id == "" ->
        errors

      customer_type in [:company, "company", "COMPANY"] ->
        digits = String.replace(tax_id, ~r/\D/, "")

        if String.length(digits) == 14 do
          errors
        else
          ["company tax_id (CNPJ) must have 14 digits" | errors]
        end

      customer_type in [:individual, "individual", "INDIVIDUAL"] ->
        digits = String.replace(tax_id, ~r/\D/, "")

        if String.length(digits) == 11 do
          errors
        else
          ["individual tax_id (CPF) must have 11 digits" | errors]
        end

      true ->
        errors
    end
  end

  defp normalize_params(params) do
    # Normalize string keys to atom keys for struct compatibility
    normalized = normalize_keys(params)

    # Handle customer_type from either string or atom key
    customer_type_value =
      Map.get(params, "customer_type", Map.get(params, :customer_type))

    # Handle active from either string or atom key (default true)
    active_value =
      Map.get(params, "active", Map.get(params, :active, true))

    normalized
    |> Map.put(:customer_type, normalize_customer_type(customer_type_value))
    |> Map.put(:active, active_value)
  end

  # Convert known string keys to atom keys for struct compatibility
  @known_keys ~w(tenant_id customer_code customer_type name trade_name tax_id email phone address active notes)a

  defp normalize_keys(params) when is_map(params) do
    Enum.reduce(@known_keys, %{}, fn key, acc ->
      string_key = Atom.to_string(key)

      value =
        case Map.fetch(params, key) do
          {:ok, v} ->
            {:found, v}

          :error ->
            case Map.fetch(params, string_key) do
              {:ok, v} -> {:found, v}
              :error -> :not_found
            end
        end

      case value do
        {:found, v} when v !== nil -> Map.put(acc, key, v)
        _ -> acc
      end
    end)
  end

  defp normalize_customer_type("INDIVIDUAL"), do: :individual
  defp normalize_customer_type("COMPANY"), do: :company
  defp normalize_customer_type("individual"), do: :individual
  defp normalize_customer_type("company"), do: :company
  defp normalize_customer_type(:individual), do: :individual
  defp normalize_customer_type(:company), do: :company
  defp normalize_customer_type(_), do: :individual

  defp parse_customer_type("INDIVIDUAL"), do: :individual
  defp parse_customer_type("COMPANY"), do: :company
  defp parse_customer_type(nil), do: :individual
  defp parse_customer_type(other) when is_atom(other), do: other
  defp parse_customer_type(_), do: :individual

  # Transformation functions (pure)

  @doc "Get display name (trade_name or name)"
  @spec display_name(t()) :: String.t()
  def display_name(%__MODULE__{trade_name: nil, name: name}), do: name
  def display_name(%__MODULE__{trade_name: "", name: name}), do: name
  def display_name(%__MODULE__{trade_name: trade_name}), do: trade_name

  @doc "Format tax_id for display (CPF/CNPJ)"
  @spec formatted_tax_id(t()) :: String.t() | nil
  def formatted_tax_id(%__MODULE__{tax_id: nil}), do: nil
  def formatted_tax_id(%__MODULE__{tax_id: ""}), do: nil

  def formatted_tax_id(%__MODULE__{tax_id: tax_id}) do
    digits = String.replace(tax_id, ~r/\D/, "")

    case String.length(digits) do
      11 ->
        # CPF: 000.000.000-00
        String.replace(digits, ~r/(\d{3})(\d{3})(\d{3})(\d{2})/, "\\1.\\2.\\3-\\4")

      14 ->
        # CNPJ: 00.000.000/0000-00
        String.replace(digits, ~r/(\d{2})(\d{3})(\d{3})(\d{4})(\d{2})/, "\\1.\\2.\\3/\\4-\\5")

      _ ->
        tax_id
    end
  end

  @doc "Convert to API response map"
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = customer) do
    %{
      id: customer.id,
      customer_code: customer.customer_code,
      customer_type:
        if(customer.customer_type,
          do: customer.customer_type |> Atom.to_string() |> String.upcase(),
          else: nil
        ),
      name: customer.name,
      trade_name: customer.trade_name,
      display_name: display_name(customer),
      tax_id: customer.tax_id,
      formatted_tax_id: formatted_tax_id(customer),
      email: customer.email,
      phone: customer.phone,
      address: customer.address,
      active: customer.active,
      created_at: customer.created_at,
      updated_at: customer.updated_at
    }
  end

  @doc "Check if customer is active"
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{active: active}), do: active == true
end

# Auditable protocol implementation
defimpl GprintEx.Domain.Auditable, for: GprintEx.Domain.Customer do
  def entity_type(_), do: "CUSTOMER"
  def entity_id(%{id: id}), do: id

  def to_audit_snapshot(customer) do
    %{
      customer_code: customer.customer_code,
      name: customer.name,
      active: customer.active
    }
  end
end
