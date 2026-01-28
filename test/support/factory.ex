defmodule GprintEx.TestFactory do
  @moduledoc """
  Test data factory for creating domain entities in tests.
  """

  alias GprintEx.Domain.{Customer, Contract, ContractItem, Service}

  @doc """
  Build a Customer struct with default or custom attributes.
  """
  def build(factory, attrs \\ %{})

  def build(:customer, attrs) do
    defaults = %{
      id: System.unique_integer([:positive]),
      tenant_id: "test-tenant",
      customer_code: "CUST#{System.unique_integer([:positive])}",
      customer_type: :company,
      name: "Test Company",
      trade_name: "Test Trade Name",
      tax_id: "12345678000199",
      email: "test@example.com",
      phone: "+5511999999999",
      address_line_1: "123 Test Street",
      city: "São Paulo",
      state: "SP",
      postal_code: "01310-100",
      country: "BR",
      active: true,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(Customer, Map.merge(defaults, attrs))
  end

  @doc """
  Build a Contract struct with default or custom attributes.
  """
  def build(:contract, attrs) do
    defaults = %{
      id: System.unique_integer([:positive]),
      tenant_id: "test-tenant",
      contract_number: "CTR-#{System.unique_integer([:positive])}",
      contract_type: :service,
      customer_id: System.unique_integer([:positive]),
      description: "Test contract",
      start_date: Date.utc_today(),
      end_date: Date.add(Date.utc_today(), 365),
      status: :draft,
      billing_cycle: "MONTHLY",
      payment_terms: 30,
      total_value: Decimal.new("0.00"),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(Contract, Map.merge(defaults, attrs))
  end

  @doc """
  Build a ContractItem struct with default or custom attributes.
  """
  def build(:contract_item, attrs) do
    defaults = %{
      id: System.unique_integer([:positive]),
      tenant_id: "test-tenant",
      contract_id: System.unique_integer([:positive]),
      line_number: 1,
      service_code: "SVC001",
      description: "Test service",
      quantity: Decimal.new(1),
      unit_price: Decimal.new("100.00"),
      discount_pct: Decimal.new(0),
      total_price: Decimal.new("100.00"),
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(ContractItem, Map.merge(defaults, attrs))
  end

  @doc """
  Build a Service struct with default or custom attributes.
  """
  def build(:service, attrs) do
    defaults = %{
      id: System.unique_integer([:positive]),
      tenant_id: "test-tenant",
      service_code: "SVC#{System.unique_integer([:positive])}",
      name: "Test Service",
      description: "A test service for contracts",
      unit_of_measure: "UNIT",
      default_price: Decimal.new("99.99"),
      active: true,
      created_at: DateTime.utc_now(),
      updated_at: DateTime.utc_now()
    }

    struct!(Service, Map.merge(defaults, attrs))
  end

  @doc """
  Build JWT claims for testing authentication.
  """
  def build(:claims, attrs) do
    defaults = %{
      user: "testuser",
      tenant_id: "test-tenant",
      login_session: "session-#{System.unique_integer([:positive])}",
      exp: System.system_time(:second) + 3600,
      iat: System.system_time(:second)
    }

    Map.merge(defaults, attrs)
  end

  @doc """
  Build a list of entities.
  """
  def build_list(count, factory, attrs \\ %{})

  def build_list(count, _factory, _attrs) when count <= 0, do: []

  def build_list(count, factory, attrs) do
    for _ <- 1..count, do: build(factory, attrs)
  end

  @doc """
  Build params map for creating entities (without id and timestamps).
  """
  def build_params(kind, attrs \\ %{})

  def build_params(:customer, attrs) do
    build(:customer, attrs)
    |> Map.from_struct()
    |> Map.drop([:id, :created_at, :updated_at])
  end

  def build_params(:contract, attrs) do
    build(:contract, attrs)
    |> Map.from_struct()
    |> Map.drop([:id, :created_at, :updated_at, :total_value])
  end

  def build_params(:contract_item, attrs) do
    build(:contract_item, attrs)
    |> Map.from_struct()
    |> Map.drop([:id, :created_at, :updated_at, :total_price])
  end

  def build_params(:service, attrs) do
    build(:service, attrs)
    |> Map.from_struct()
    |> Map.drop([:id, :created_at, :updated_at])
  end
end
