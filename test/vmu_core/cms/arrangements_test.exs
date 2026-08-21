defmodule VmuCore.CMS.ArrangementsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Koṣa domain-model alignment
  (`docs/cms/core-domain-new-docs.md`, 2026-07-28) — `CMS.Arrangement`
  is the real cross-product index: one row per customer relationship,
  pointing at whichever of `CMS.Account`/`DebitAccount`/`PrepaidAccount`/
  `HCS.EmployeeCard`/`FleetCard` actually holds the money/status, never
  duplicating it.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Arrangement, Arrangements}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "record/1" do
    test "creates an arrangement with today as the default opened_at" do
      customer_id = Ecto.UUID.generate()

      assert {:ok, arrangement} =
               Arrangements.record(%{
                 customer_id: customer_id, product_type: "DEBIT",
                 account_ref: Ecto.UUID.generate()
               })

      assert arrangement.opened_at == Date.utc_today()
    end

    test "accepts a plain-integer-style account_ref (HCS's non-UUID primary keys)" do
      assert {:ok, arrangement} =
               Arrangements.record(%{
                 customer_id: Ecto.UUID.generate(), product_type: "CORPORATE_FACILITY",
                 account_ref: to_string(42)
               })

      assert arrangement.account_ref == "42"
    end

    test "rejects an unknown product_type" do
      assert {:error, changeset} =
               Arrangements.record(%{
                 customer_id: Ecto.UUID.generate(), product_type: "BOGUS",
                 account_ref: Ecto.UUID.generate()
               })

      refute changeset.valid?
    end

    test "rejects a duplicate (product_type, account_ref) pair" do
      account_ref = Ecto.UUID.generate()

      assert {:ok, _} =
               Arrangements.record(%{
                 customer_id: Ecto.UUID.generate(), product_type: "PREPAID", account_ref: account_ref
               })

      assert {:error, changeset} =
               Arrangements.record(%{
                 customer_id: Ecto.UUID.generate(), product_type: "PREPAID", account_ref: account_ref
               })

      refute changeset.valid?
    end

    test "the same account_ref under a different product_type is fine (no cross-product collision)" do
      account_ref = Ecto.UUID.generate()

      assert {:ok, _} =
               Arrangements.record(%{
                 customer_id: Ecto.UUID.generate(), product_type: "CREDIT", account_ref: account_ref
               })

      assert {:ok, _} =
               Arrangements.record(%{
                 customer_id: Ecto.UUID.generate(), product_type: "DEBIT", account_ref: account_ref
               })
    end
  end

  describe "list_for_customer/1" do
    test "returns only that customer's arrangements, newest first" do
      customer_id = Ecto.UUID.generate()
      other_customer_id = Ecto.UUID.generate()

      {:ok, first} =
        Arrangements.record(%{customer_id: customer_id, product_type: "CREDIT", account_ref: Ecto.UUID.generate()})
      {:ok, second} =
        Arrangements.record(%{customer_id: customer_id, product_type: "DEBIT", account_ref: Ecto.UUID.generate()})
      {:ok, _other} =
        Arrangements.record(%{customer_id: other_customer_id, product_type: "PREPAID", account_ref: Ecto.UUID.generate()})

      results = Arrangements.list_for_customer(customer_id)
      assert length(results) == 2
      assert Enum.map(results, & &1.id) |> Enum.sort() == Enum.sort([first.id, second.id])
    end

    test "returns an empty list for a customer with no arrangements" do
      assert Arrangements.list_for_customer(Ecto.UUID.generate()) == []
    end
  end

  test "product_types/0 exposes the valid list" do
    assert "CREDIT" in Arrangement.product_types()
    assert "DEBIT" in Arrangement.product_types()
    assert "PREPAID" in Arrangement.product_types()
    assert "CORPORATE_FACILITY" in Arrangement.product_types()
    assert "CORPORATE_EMPLOYEE" in Arrangement.product_types()
    assert "CORPORATE_FLEET" in Arrangement.product_types()
  end
end
