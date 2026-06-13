defmodule VmuCore.CDM.UnderwritingTest do
  use ExUnit.Case, async: true

  alias VmuCore.CDM.LimitAllocator
  alias Decimal, as: D

  @sys_id "SYS01"
  @bank_id "BANK01"
  @logo_id "LOGO01"

  describe "LimitAllocator.calculate/6" do
    test "PRIME tier: 2x income multiplier" do
      {:ok, limit} = LimitAllocator.calculate(D.new("5000"), :prime, @sys_id, @bank_id, @logo_id)
      # 5000 × 2.0 = 10000, rounded to nearest 100
      assert D.compare(limit, D.new("10000")) == :eq
    end

    test "NEAR_PRIME tier: 1x income multiplier" do
      {:ok, limit} = LimitAllocator.calculate(D.new("5000"), :near_prime, @sys_id, @bank_id, @logo_id)
      assert D.compare(limit, D.new("5000")) == :eq
    end

    test "SUBPRIME tier: 0.5x income multiplier" do
      {:ok, limit} = LimitAllocator.calculate(D.new("5000"), :subprime, @sys_id, @bank_id, @logo_id)
      assert D.compare(limit, D.new("2500")) == :eq
    end

    test "DECLINE tier returns error" do
      assert {:error, :tier_declined} =
        LimitAllocator.calculate(D.new("5000"), :decline, @sys_id, @bank_id, @logo_id)
    end

    test "DSR cap exceeded returns error (G9)" do
      # Income: 3000/month
      # Existing payments: 1400/month (already 46.7% DSR)
      # Proposed limit: 5000 → min payment = 250 (5%)
      # DSR = (1400 + 250) / 3000 = 55% > 50% → should reject
      assert {:error, :dsr_cap_exceeded} =
        LimitAllocator.calculate(D.new("3000"), :prime, @sys_id, @bank_id, @logo_id, D.new("1400"))
    end

    test "DSR within cap passes (G9)" do
      # Income: 10000, existing: 0, proposed limit: 20000 → min = 1000
      # DSR = 1000 / 10000 = 10% < 50%
      assert {:ok, _} =
        LimitAllocator.calculate(D.new("10000"), :prime, @sys_id, @bank_id, @logo_id, D.new("0"))
    end

    test "rounds limit to nearest 100" do
      {:ok, limit} = LimitAllocator.calculate(D.new("4234"), :near_prime, @sys_id, @bank_id, @logo_id)
      # 4234 × 1.0 = 4234 → rounded up to 4300
      assert D.compare(limit, D.new("4300")) == :eq
    end
  end
end
