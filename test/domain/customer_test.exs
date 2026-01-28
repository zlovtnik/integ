defmodule GprintEx.Domain.CustomerTest do
  use ExUnit.Case, async: true

  alias GprintEx.Domain.Customer

  describe "new/1" do
    test "creates customer with valid params" do
      params = %{
        tenant_id: "tenant-1",
        customer_code: "CUST001",
        name: "Acme Corp",
        customer_type: :company,
        email: "contact@acme.com"
      }

      assert {:ok, customer} = Customer.new(params)
      assert customer.tenant_id == "tenant-1"
      assert customer.customer_code == "CUST001"
      assert customer.name == "Acme Corp"
      assert customer.customer_type == :company
      assert customer.active == true
    end

    test "fails with missing required fields" do
      params = %{tenant_id: "tenant-1"}

      assert {:error, :validation_failed, errors} = Customer.new(params)
      assert "customer_code is required" in errors
      assert "name is required" in errors
    end

    test "validates email format" do
      params = %{
        tenant_id: "tenant-1",
        customer_code: "CUST001",
        name: "Acme Corp",
        email: "invalid-email"
      }

      assert {:error, :validation_failed, errors} = Customer.new(params)
      assert "invalid email format" in errors
    end

    test "validates CNPJ for company" do
      params = %{
        tenant_id: "tenant-1",
        customer_code: "CUST001",
        name: "Acme Corp",
        customer_type: :company,
        tax_id: "123"
      }

      assert {:error, :validation_failed, errors} = Customer.new(params)
      assert "company tax_id (CNPJ) must have 14 digits" in errors
    end

    test "validates CPF for individual" do
      params = %{
        tenant_id: "tenant-1",
        customer_code: "CUST001",
        name: "John Doe",
        customer_type: :individual,
        tax_id: "123"
      }

      assert {:error, :validation_failed, errors} = Customer.new(params)
      assert "individual tax_id (CPF) must have 11 digits" in errors
    end
  end

  describe "display_name/1" do
    test "returns trade_name when present" do
      customer = %Customer{
        tenant_id: "t1",
        customer_code: "C1",
        name: "Legal Name",
        trade_name: "Trade Name"
      }

      assert "Trade Name" = Customer.display_name(customer)
    end

    test "returns name when trade_name is nil" do
      customer = %Customer{
        tenant_id: "t1",
        customer_code: "C1",
        name: "Legal Name",
        trade_name: nil
      }

      assert "Legal Name" = Customer.display_name(customer)
    end
  end

  describe "formatted_tax_id/1" do
    test "formats CPF" do
      customer = %Customer{
        tenant_id: "t1",
        customer_code: "C1",
        name: "John",
        tax_id: "12345678901"
      }

      assert "123.456.789-01" = Customer.formatted_tax_id(customer)
    end

    test "formats CNPJ" do
      customer = %Customer{
        tenant_id: "t1",
        customer_code: "C1",
        name: "Corp",
        tax_id: "12345678000199"
      }

      assert "12.345.678/0001-99" = Customer.formatted_tax_id(customer)
    end

    test "returns nil for nil tax_id" do
      customer = %Customer{
        tenant_id: "t1",
        customer_code: "C1",
        name: "John",
        tax_id: nil
      }

      assert nil == Customer.formatted_tax_id(customer)
    end
  end

  describe "to_response/1" do
    test "converts to response map" do
      customer = %Customer{
        id: 1,
        tenant_id: "t1",
        customer_code: "C1",
        customer_type: :company,
        name: "Acme",
        trade_name: "Acme Inc",
        tax_id: "12345678000199",
        email: "acme@example.com",
        active: true
      }

      response = Customer.to_response(customer)

      assert response.id == 1
      assert response.customer_code == "C1"
      assert response.customer_type == "COMPANY"
      assert response.display_name == "Acme Inc"
      assert response.formatted_tax_id == "12.345.678/0001-99"
    end
  end
end
