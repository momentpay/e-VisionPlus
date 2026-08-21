defmodule VmuCore.CMS.MinimumPaymentTest do
  @moduledoc """
  `InterestEngine.minimum_payment_pct_of_balance/3` — the PERCENTAGE_OF_BALANCE
  model that `logo_parameters.min_payment_calculation` selects for every
  configured product.

  Tested because it is a financial calculation that bills a cardholder, and
  because it replaced a call to a function that did not exist: the caller
  invoked `minimum_payment/2` while the only definition was the component-based
  `/5`, passing `min_pct` where `fees_due` belonged. Statement generation raised
  for every account until this was fixed.
  """
  use ExUnit.Case, async: true

  alias VmuCore.CMS.InterestEngine
  alias Decimal, as: D

  @floor D.new("25.00")

  describe "percentage of balance" do
    test "bills the configured percentage when it exceeds the floor" do
      # 5% of 1000 = 50, above the 25 floor
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("1000.00"), D.new("5.0"), @floor),
               D.new("50.00")
             )
    end

    test "falls back to the floor when the percentage is below it" do
      # 5% of 100 = 5, below the 25 floor
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("100.00"), D.new("5.0"), @floor),
               @floor
             )
    end

    test "never bills more than the balance itself" do
      # A 25 floor against a 10 balance must not demand 25 — the cardholder
      # does not owe it.
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("10.00"), D.new("5.0"), @floor),
               D.new("10.00")
             )
    end

    test "a zero balance bills nothing" do
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("0.00"), D.new("5.0"), @floor),
               D.new("0.00")
             )
    end

    test "rounds up to the cent, never in the cardholder's favour by a fraction" do
      # 5% of 333.33 = 16.6665 -> 16.67, then floored to 25
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("333.33"), D.new("5.0"), D.new("1.00")),
               D.new("16.67")
             )
    end

    test "a balance exactly at the floor bills the floor" do
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("25.00"), D.new("5.0"), @floor),
               @floor
             )
    end
  end

  describe "unit guard" do
    test "a fraction is rejected rather than under-billing by 100x" do
      # 0.05 would compute 0.05% of the balance instead of 5%. The parameter
      # cascade stores 5.0000, so a fraction here means a caller got the units
      # wrong — silently billing 1/100th of the correct amount is worse than
      # raising.
      assert_raise ArgumentError, ~r/percentage/, fn ->
        InterestEngine.minimum_payment_pct_of_balance(D.new("1000.00"), D.new("0.05"), @floor)
      end
    end

    test "100% is accepted — it is a legitimate configuration" do
      assert D.equal?(
               InterestEngine.minimum_payment_pct_of_balance(D.new("500.00"), D.new("100.0"), @floor),
               D.new("500.00")
             )
    end
  end

  describe "the component-based model is untouched" do
    test "minimum_payment/5 still implements interest + fees + past due + principal" do
      result =
        InterestEngine.minimum_payment(
          D.new("50.00"),
          D.new("25.00"),
          D.new("0.00"),
          D.new("2000.00"),
          D.new("25.00")
        )

      # 50 + 25 + 0 + max(1% of 2000 = 20, floor 25) = 100
      assert D.equal?(result, D.new("100.00"))
    end
  end
end
