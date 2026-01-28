defmodule GprintEx.Domain.ContractTest do
  use ExUnit.Case, async: true

  alias GprintEx.Domain.Contract

  describe "new/1" do
    test "creates contract with valid params" do
      params = %{
        tenant_id: "tenant-1",
        contract_number: "CTR-2024-001",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        contract_type: :service
      }

      assert {:ok, contract} = Contract.new(params)
      assert contract.tenant_id == "tenant-1"
      assert contract.contract_number == "CTR-2024-001"
      assert contract.customer_id == 1
      assert contract.status == :draft
    end

    test "fails with missing required fields" do
      params = %{tenant_id: "tenant-1"}

      assert {:error, :validation_failed, errors} = Contract.new(params)
      assert "contract_number is required" in errors
      assert "customer_id is required" in errors
      assert "start_date is required" in errors
    end

    test "validates date order" do
      params = %{
        tenant_id: "tenant-1",
        contract_number: "CTR-001",
        customer_id: 1,
        contract_type: :service,
        start_date: ~D[2024-12-31],
        end_date: ~D[2024-01-01]
      }

      assert {:error, :validation_failed, errors} = Contract.new(params)
      assert "end_date must be after start_date" in errors
    end
  end

  describe "status transitions" do
    test "can_transition?/2 allows valid transitions" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :draft
      }

      assert Contract.can_transition?(contract, :pending)
      assert Contract.can_transition?(contract, :cancelled)
      refute Contract.can_transition?(contract, :active)
      refute Contract.can_transition?(contract, :completed)
    end

    test "transition/2 updates status for valid transition" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :draft
      }

      assert {:ok, transitioned} = Contract.transition(contract, :pending)
      assert transitioned.status == :pending
    end

    test "transition/2 fails for invalid transition" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :cancelled
      }

      assert {:error, :invalid_transition} = Contract.transition(contract, :active)
    end

    test "allowed_transitions/1 returns valid next statuses" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :active
      }

      allowed = Contract.allowed_transitions(contract)
      assert :suspended in allowed
      assert :completed in allowed
      assert :cancelled in allowed
      refute :draft in allowed
    end
  end

  describe "calculate_totals/2" do
    test "calculates total from items" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :draft
      }

      items = [
        %{quantity: 2, unit_price: 100, discount_pct: 0},
        %{quantity: 1, unit_price: 50, discount_pct: 10}
      ]

      assert {:ok, updated} = Contract.calculate_totals(contract, items)
      # 2*100 + 1*50*0.9 = 200 + 45 = 245
      assert Decimal.compare(updated.total_value, Decimal.new(245)) == :eq
    end

    test "empty items list returns total_value zero" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :draft
      }

      assert {:ok, updated} = Contract.calculate_totals(contract, [])
      assert Decimal.compare(updated.total_value, Decimal.new(0)) == :eq
    end

    test "items with 100% discount yield zero line totals" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :draft
      }

      items = [
        %{quantity: 5, unit_price: 200, discount_pct: 100},
        %{quantity: 3, unit_price: 100, discount_pct: 100}
      ]

      assert {:ok, updated} = Contract.calculate_totals(contract, items)
      assert Decimal.compare(updated.total_value, Decimal.new(0)) == :eq
    end

    test "items with zero quantity or zero unit_price do not affect total" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        status: :draft
      }

      items = [
        %{quantity: 0, unit_price: 100, discount_pct: 0},
        %{quantity: 5, unit_price: 0, discount_pct: 0},
        %{quantity: 2, unit_price: 50, discount_pct: 0}
      ]

      assert {:ok, updated} = Contract.calculate_totals(contract, items)
      # Only 2*50 = 100 contributes
      assert Decimal.compare(updated.total_value, Decimal.new(100)) == :eq
    end
  end

  describe "expiry functions" do
    test "expired?/1 returns true for past end_date" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2020-01-01],
        end_date: ~D[2020-12-31],
        status: :active
      }

      assert Contract.expired?(contract)
    end

    test "expired?/1 returns false for nil end_date" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        end_date: nil,
        status: :active
      }

      refute Contract.expired?(contract)
    end

    test "days_until_expiry/1 returns nil for nil end_date" do
      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        end_date: nil,
        status: :active
      }

      assert nil == Contract.days_until_expiry(contract)
    end

    test "days_until_expiry/1 returns days until end_date" do
      end_date = Date.add(Date.utc_today(), 30)

      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        end_date: end_date,
        status: :active
      }

      assert Contract.days_until_expiry(contract) == 30
    end

    test "expiring_soon?/1 detects contracts expiring within threshold" do
      # Contract expiring in 15 days
      end_date = Date.add(Date.utc_today(), 15)

      contract = %Contract{
        tenant_id: "t1",
        contract_number: "C1",
        customer_id: 1,
        start_date: ~D[2024-01-01],
        end_date: end_date,
        status: :active
      }

      assert Contract.expiring_soon?(contract, 30)
      refute Contract.expiring_soon?(contract, 10)
    end
  end

  describe "to_response/1" do
    test "converts to response map with computed fields" do
      contract = %Contract{
        id: 1,
        tenant_id: "t1",
        contract_number: "CTR-001",
        contract_type: :service,
        customer_id: 42,
        start_date: ~D[2024-01-01],
        end_date: Date.add(Date.utc_today(), 30),
        status: :active,
        total_value: Decimal.new("1000.00"),
        billing_cycle: "MONTHLY"
      }

      response = Contract.to_response(contract)

      assert response.id == 1
      assert response.contract_number == "CTR-001"
      assert response.contract_type == "SERVICE"
      assert response.status == "ACTIVE"
      assert response.total_value == "1000.00"
      assert response.is_expired == false
      assert is_integer(response.days_until_expiry)
      assert is_list(response.allowed_transitions)
    end
  end
end
