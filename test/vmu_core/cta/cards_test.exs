defmodule VmuCore.CTA.CardsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers `Cards.by_customer/1`
  only — NTS Phase F6 (2026-08-02), the first real consumer. No prior
  test file existed for `CTA.Cards` at all (a real pre-existing gap,
  out of scope to fully backfill here).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, DebitAccount, PrepaidAccount}
  alias VmuCore.CTA.{Card, Cards}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp parameter_hierarchy_fixture(product_type) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541238", description: "test", product_type: product_type, card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id, n}
  end

  test "by_customer/1 returns cards across Credit, Debit, and Prepaid for the same customer, and none for another" do
    {sys_id, bank_id, logo_id, block_id, n} = parameter_hierarchy_fixture("CREDIT")

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Cards", last_name: "ByCustomer#{n}"})
      |> Repo.insert!()

    credit_account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
        pan_token: pan_token("by-customer-credit-#{n}"), last_four: "0001", expiry_date: "1230",
        credit_limit: D.new("1000.00"), emboss_name: "CREDIT CARD#{n}"
      })
      |> Repo.insert!()

    debit_account =
      %DebitAccount{}
      |> DebitAccount.changeset(%{customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id, opened_at: Date.utc_today()})
      |> Repo.insert!()

    prepaid_account =
      %PrepaidAccount{}
      |> PrepaidAccount.changeset(%{customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id, opened_at: Date.utc_today()})
      |> Repo.insert!()

    {:ok, credit_card} = Cards.issue(%{account_id: credit_account.account_id, pan_token: pan_token("by-customer-credit-#{n}"), card_type: "PRIMARY", status: "ACTIVE"})
    {:ok, debit_card} = Cards.issue(%{debit_account_id: debit_account.debit_account_id, pan_token: pan_token("by-customer-debit-#{n}"), card_type: "PRIMARY", status: "ACTIVE"})
    {:ok, prepaid_card} = Cards.issue(%{prepaid_account_id: prepaid_account.prepaid_account_id, pan_token: pan_token("by-customer-prepaid-#{n}"), card_type: "PRIMARY", status: "ACTIVE"})

    other_customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Other", last_name: "Customer#{n}"})
      |> Repo.insert!()

    cards = Cards.by_customer(customer.customer_id)
    card_ids = Enum.map(cards, & &1.card_id)

    assert credit_card.card_id in card_ids
    assert debit_card.card_id in card_ids
    assert prepaid_card.card_id in card_ids
    assert length(cards) == 3

    assert Cards.by_customer(other_customer.customer_id) == []
  end
end
