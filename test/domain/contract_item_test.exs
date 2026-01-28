defmodule GprintEx.Domain.ContractItemTest do
  use ExUnit.Case, async: true

  alias GprintEx.Domain.ContractItem

  describe "new/1" do
    test "creates item with valid params" do
      params = %{
        tenant_id: "tenant-1",
        contract_id: 1,
        description: "Monthly service fee",
        quantity: 1,
        unit_price: 100
      }

      assert {:ok, item} = ContractItem.new(params)
      assert item.tenant_id == "tenant-1"
      assert item.contract_id == 1
      assert item.description == "Monthly service fee"
      assert Decimal.compare(item.quantity, Decimal.new(1)) == :eq
      assert Decimal.compare(item.unit_price, Decimal.new(100)) == :eq
    end

    test "calculates total price" do
      params = %{
        tenant_id: "tenant-1",
        contract_id: 1,
        description: "Service",
        quantity: 2,
        unit_price: 100,
        discount_pct: 10
      }

      assert {:ok, item} = ContractItem.new(params)
      # 2 * 100 * 0.9 = 180
      assert Decimal.compare(item.total_price, Decimal.new(180)) == :eq
    end

    test "fails with missing required fields" do
      params = %{tenant_id: "tenant-1", contract_id: 1}

      assert {:error, :validation_failed, errors} = ContractItem.new(params)
      assert "description is required" in errors
    end

    test "validates quantity is positive" do
      params = %{
        tenant_id: "tenant-1",
        contract_id: 1,
        description: "Service",
        quantity: 0,
        unit_price: 100
      }

      assert {:error, :validation_failed, errors} = ContractItem.new(params)
      assert "quantity must be positive" in errors
    end
  end

  describe "calculate_total/1" do
    test "applies discount correctly" do
      item = %ContractItem{
        tenant_id: "t1",
        contract_id: 1,
        description: "Test",
        quantity: Decimal.new(5),
        unit_price: Decimal.new(200),
        discount_pct: Decimal.new(25)
      }

      updated = ContractItem.calculate_total(item)
      # 5 * 200 * 0.75 = 750
      assert Decimal.compare(updated.total_price, Decimal.new(750)) == :eq
    end
  end

  describe "to_response/1" do
    test "converts to response map" do
      item = %ContractItem{
        id: 1,
        tenant_id: "t1",
        contract_id: 1,
        line_number: 1,
        description: "Monthly service",
        quantity: Decimal.new(2),
        unit_price: Decimal.new("150.50"),
        discount_pct: Decimal.new(5),
        total_price: Decimal.new("285.95")
      }

      response = ContractItem.to_response(item)

      assert response.id == 1
      assert response.line_number == 1
      assert response.description == "Monthly service"
      assert response.quantity == "2"
      assert response.unit_price == "150.50"
      assert response.total_price == "285.95"
    end
  end
end
