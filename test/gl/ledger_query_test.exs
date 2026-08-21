defmodule VmuCore.GL.LedgerQueryTest do
  @moduledoc """
  `GL.LedgerQuery` — the read API readers migrate onto in Phase C2.

  The vocabulary-translation tests matter most. Wallet withdrawals post as
  `PURCHASE` in the legacy enum and both adjustment directions collapse to
  `ADJUSTMENT`, so a reader that assumed the two vocabularies matched would
  silently miss rows.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.GL.LedgerQuery

  describe "legacy transaction_code translation" do
    test "PURCHASE covers wallet withdrawals, which post as PURCHASE in the legacy enum" do
      assert LedgerQuery.events_for_legacy_code("PURCHASE") == ["PURCHASE", "WITHDRAWAL"]
    end

    test "ADJUSTMENT covers both directions, which share one legacy code" do
      assert LedgerQuery.events_for_legacy_code("ADJUSTMENT") ==
               ["ADJUSTMENT_CREDIT", "ADJUSTMENT_DEBIT"]
    end

    test "codes with no divergence map to themselves" do
      for code <- ~w[PAYMENT INTEREST FEE DEPOSIT CASH_ADV REVERSAL DISPUTE_CREDIT] do
        assert LedgerQuery.events_for_legacy_code(code) == [code]
      end
    end

    test "an unknown code passes through rather than silently matching nothing" do
      assert LedgerQuery.events_for_legacy_code("SOMETHING_NEW") == ["SOMETHING_NEW"]
    end
  end

  describe "aggregates" do
    test "sum_amount returns a zero Decimal, never nil" do
      result = LedgerQuery.sum_amount(account_ref: Ecto.UUID.generate())

      assert %Decimal{} = result
      assert Decimal.equal?(result, Decimal.new(0))
    end

    test "count returns 0 for an account with no postings" do
      assert LedgerQuery.count(account_ref: Ecto.UUID.generate()) == 0
    end

    test "exists? is false for an account with no postings" do
      refute LedgerQuery.exists?(account_ref: Ecto.UUID.generate())
    end

    test "account_refs returns an empty list, not nil" do
      assert LedgerQuery.account_refs(on: ~D[1999-01-01]) == []
    end
  end

  describe "filter validation" do
    test "an unknown filter raises rather than being silently ignored" do
      # Ignoring an unrecognised filter would widen the query without saying
      # so — a reader asking for a subset would get the whole ledger.
      assert_raise ArgumentError, ~r/unknown LedgerQuery filter/, fn ->
        LedgerQuery.sum_amount(acount_ref: "typo")
      end
    end

    test "limit is accepted without being treated as a filter" do
      assert LedgerQuery.entries(account_ref: Ecto.UUID.generate(), limit: 5) == []
    end
  end
end
