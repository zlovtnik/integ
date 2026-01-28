defmodule GprintEx.Domain.Contract do
  @moduledoc """
  Contract domain entity with state machine.
  Pure functions - no side effects.
  """

  alias GprintEx.Domain.Types

  @type status :: :draft | :pending | :active | :suspended | :cancelled | :completed
  @type contract_type :: :service | :recurring | :project

  @type t :: %__MODULE__{
          id: pos_integer() | nil,
          tenant_id: Types.tenant_id(),
          contract_number: String.t(),
          contract_type: contract_type(),
          customer_id: pos_integer(),
          start_date: Date.t(),
          end_date: Date.t() | nil,
          duration_months: pos_integer() | nil,
          auto_renew: boolean(),
          total_value: Decimal.t() | nil,
          payment_terms: String.t() | nil,
          billing_cycle: String.t(),
          status: status(),
          signed_at: DateTime.t() | nil,
          signed_by: String.t() | nil,
          notes: String.t() | nil,
          created_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil,
          created_by: String.t() | nil,
          updated_by: String.t() | nil
        }

  @enforce_keys [:tenant_id, :contract_number, :customer_id, :start_date]
  defstruct [
    :id,
    :tenant_id,
    :contract_number,
    :contract_type,
    :customer_id,
    :start_date,
    :end_date,
    :duration_months,
    :auto_renew,
    :total_value,
    :payment_terms,
    :billing_cycle,
    :status,
    :signed_at,
    :signed_by,
    :notes,
    :created_at,
    :updated_at,
    :created_by,
    :updated_by
  ]

  # Status transition matrix (from -> [allowed_to])
  @transitions %{
    draft: [:pending, :cancelled],
    pending: [:active, :draft, :cancelled],
    active: [:suspended, :completed, :cancelled],
    suspended: [:active, :cancelled],
    cancelled: [],
    completed: []
  }

  @doc "Create new contract from params"
  @spec new(map()) :: {:ok, t()} | {:error, :validation_failed, [String.t()]}
  def new(params) do
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
       contract_number: row[:contract_number],
       contract_type: parse_contract_type(row[:contract_type]),
       customer_id: row[:customer_id],
       start_date: parse_date(row[:start_date]),
       end_date: parse_date(row[:end_date]),
       duration_months: row[:duration_months],
       auto_renew: row[:auto_renew] == 1 or row[:auto_renew] == true,
       total_value: parse_decimal(row[:total_value]),
       payment_terms: row[:payment_terms],
       billing_cycle: row[:billing_cycle] || "MONTHLY",
       status: parse_status(row[:status]),
       signed_at: row[:signed_at],
       signed_by: row[:signed_by],
       notes: row[:notes],
       created_at: row[:created_at],
       updated_at: row[:updated_at],
       created_by: row[:created_by],
       updated_by: row[:updated_by]
     }}
  end

  @doc "Check if status transition is allowed"
  @spec can_transition?(t(), status()) :: boolean()
  def can_transition?(%__MODULE__{status: current}, new_status) do
    new_status in Map.get(@transitions, current, [])
  end

  @doc "Get allowed transitions from current status"
  @spec allowed_transitions(t()) :: [status()]
  def allowed_transitions(%__MODULE__{status: current}) do
    Map.get(@transitions, current, [])
  end

  @doc "Transition contract status"
  @spec transition(t(), status()) :: {:ok, t()} | {:error, :invalid_transition}
  def transition(%__MODULE__{} = contract, new_status) do
    if can_transition?(contract, new_status) do
      {:ok, %{contract | status: new_status}}
    else
      {:error, :invalid_transition}
    end
  end

  @doc "Calculate totals from items"
  @spec calculate_totals(t(), [map()]) :: {:ok, t()}
  def calculate_totals(%__MODULE__{} = contract, items) do
    total =
      items
      |> Enum.map(fn item ->
        qty = safe_decimal(item, :quantity, "quantity", Decimal.new(1))
        price = safe_decimal(item, :unit_price, "unit_price", Decimal.new(0))
        discount = safe_decimal(item, :discount_pct, "discount_pct", Decimal.new(0))
        discount_factor = Decimal.sub(Decimal.new(1), Decimal.div(discount, Decimal.new(100)))
        Decimal.mult(Decimal.mult(qty, price), discount_factor)
      end)
      |> Enum.reduce(Decimal.new(0), &Decimal.add/2)

    {:ok, %{contract | total_value: total}}
  end

  # Safely extract and coerce a decimal value from item (supports atom and string keys)
  defp safe_decimal(item, atom_key, string_key, default) do
    value = Map.get(item, atom_key) || Map.get(item, string_key)
    coerce_to_decimal(value, default)
  end

  defp coerce_to_decimal(nil, default), do: default
  defp coerce_to_decimal(%Decimal{} = d, _default), do: d
  defp coerce_to_decimal(n, _default) when is_integer(n), do: Decimal.new(n)
  defp coerce_to_decimal(n, _default) when is_float(n), do: Decimal.from_float(n)

  defp coerce_to_decimal(s, default) when is_binary(s) do
    case Decimal.parse(s) do
      {decimal, ""} -> decimal
      _ -> default
    end
  end

  defp coerce_to_decimal(_, default), do: default

  @doc "Check if contract is active"
  @spec active?(t()) :: boolean()
  def active?(%__MODULE__{status: :active}), do: true
  def active?(_), do: false

  @doc "Check if contract is expired"
  @spec expired?(t()) :: boolean()
  def expired?(%__MODULE__{end_date: nil}), do: false

  def expired?(%__MODULE__{end_date: end_date}) do
    Date.compare(end_date, Date.utc_today()) == :lt
  end

  @doc "Days until expiration (nil if no end_date)"
  @spec days_until_expiry(t()) :: integer() | nil
  def days_until_expiry(%__MODULE__{end_date: nil}), do: nil

  def days_until_expiry(%__MODULE__{end_date: end_date}) do
    Date.diff(end_date, Date.utc_today())
  end

  @doc "Check if contract is expiring soon (within n days)"
  @spec expiring_soon?(t(), pos_integer()) :: boolean()
  def expiring_soon?(%__MODULE__{} = contract, days \\ 30) do
    case days_until_expiry(contract) do
      nil -> false
      remaining -> remaining >= 0 and remaining <= days
    end
  end

  @doc "Convert to API response map"
  @spec to_response(t()) :: map()
  def to_response(%__MODULE__{} = contract) do
    %{
      id: contract.id,
      contract_number: contract.contract_number,
      contract_type: atom_to_upper(contract.contract_type),
      customer_id: contract.customer_id,
      start_date: contract.start_date,
      end_date: contract.end_date,
      duration_months: contract.duration_months,
      auto_renew: contract.auto_renew,
      total_value: contract.total_value && Decimal.to_string(contract.total_value),
      payment_terms: contract.payment_terms,
      billing_cycle: contract.billing_cycle,
      status: atom_to_upper(contract.status),
      signed_at: contract.signed_at,
      signed_by: contract.signed_by,
      notes: contract.notes,
      days_until_expiry: days_until_expiry(contract),
      is_expired: expired?(contract),
      allowed_transitions: Enum.map(allowed_transitions(contract), &atom_to_upper/1),
      created_at: contract.created_at,
      updated_at: contract.updated_at
    }
  end

  # Private

  defp validate(params) do
    errors =
      []
      |> validate_required(params, :tenant_id)
      |> validate_required(params, :contract_number)
      |> validate_required(params, :customer_id)
      |> validate_required(params, :start_date)
      |> validate_date_order(params)

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

  defp validate_date_order(errors, params) do
    start_date = Map.get(params, :start_date) || Map.get(params, "start_date")
    end_date = Map.get(params, :end_date) || Map.get(params, "end_date")
    parsed_start = parse_date(start_date)
    parsed_end = parse_date(end_date)

    cond do
      is_nil(parsed_end) ->
        errors

      is_nil(parsed_start) ->
        errors

      Date.compare(parsed_start, parsed_end) == :gt ->
        ["end_date must be after start_date" | errors]

      true ->
        errors
    end
  end

  defp normalize(params) do
    %{
      tenant_id: Map.get(params, :tenant_id) || Map.get(params, "tenant_id"),
      contract_number: Map.get(params, :contract_number) || Map.get(params, "contract_number"),
      contract_type:
        normalize_contract_type(Map.get(params, :contract_type) || Map.get(params, "contract_type")),
      customer_id: Map.get(params, :customer_id) || Map.get(params, "customer_id"),
      start_date: parse_date(Map.get(params, :start_date) || Map.get(params, "start_date")),
      end_date: parse_date(Map.get(params, :end_date) || Map.get(params, "end_date")),
      duration_months: Map.get(params, :duration_months) || Map.get(params, "duration_months"),
      auto_renew: Map.get(params, :auto_renew, false),
      total_value: parse_decimal(Map.get(params, :total_value)),
      payment_terms: Map.get(params, :payment_terms),
      billing_cycle: Map.get(params, :billing_cycle, "MONTHLY"),
      status: normalize_status(Map.get(params, :status)) || :draft,
      signed_at: Map.get(params, :signed_at),
      signed_by: Map.get(params, :signed_by),
      notes: Map.get(params, :notes)
    }
  end

  defp normalize_contract_type("SERVICE"), do: :service
  defp normalize_contract_type("RECURRING"), do: :recurring
  defp normalize_contract_type("PROJECT"), do: :project
  defp normalize_contract_type(:service), do: :service
  defp normalize_contract_type(:recurring), do: :recurring
  defp normalize_contract_type(:project), do: :project
  defp normalize_contract_type(_), do: :service

  defp parse_contract_type("SERVICE"), do: :service
  defp parse_contract_type("RECURRING"), do: :recurring
  defp parse_contract_type("PROJECT"), do: :project
  defp parse_contract_type(nil), do: :service
  defp parse_contract_type(other) when is_atom(other), do: other
  defp parse_contract_type(_), do: :service

  defp normalize_status("DRAFT"), do: :draft
  defp normalize_status("PENDING"), do: :pending
  defp normalize_status("ACTIVE"), do: :active
  defp normalize_status("SUSPENDED"), do: :suspended
  defp normalize_status("CANCELLED"), do: :cancelled
  defp normalize_status("COMPLETED"), do: :completed
  defp normalize_status(status) when is_atom(status), do: status
  defp normalize_status(_), do: :draft

  defp parse_status("DRAFT"), do: :draft
  defp parse_status("PENDING"), do: :pending
  defp parse_status("ACTIVE"), do: :active
  defp parse_status("SUSPENDED"), do: :suspended
  defp parse_status("CANCELLED"), do: :cancelled
  defp parse_status("COMPLETED"), do: :completed
  defp parse_status(nil), do: :draft
  defp parse_status(other) when is_atom(other), do: other
  defp parse_status(_), do: :draft

  defp parse_date(nil), do: nil
  defp parse_date(%Date{} = date), do: date
  defp parse_date(%DateTime{} = dt), do: DateTime.to_date(dt)
  defp parse_date(%NaiveDateTime{} = ndt), do: NaiveDateTime.to_date(ndt)

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, date} -> date
      _ -> nil
    end
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

  defp atom_to_upper(nil), do: nil
  defp atom_to_upper(atom) when is_atom(atom), do: atom |> Atom.to_string() |> String.upcase()
  defp atom_to_upper(other), do: other
end

# Auditable protocol implementation
defimpl GprintEx.Domain.Auditable, for: GprintEx.Domain.Contract do
  def entity_type(_), do: "CONTRACT"
  def entity_id(%{id: id}), do: id

  def to_audit_snapshot(contract) do
    %{
      contract_number: contract.contract_number,
      status: contract.status,
      total_value: contract.total_value,
      customer_id: contract.customer_id
    }
  end
end
