defmodule VmuCore.CMS.ArrangementsSearchTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Koṣa domain-model alignment
  (2026-07-28) — `Arrangements.search/1` is the cross-product rollup
  behind the "All Products" tab on the Accounts admin page: confirms it
  actually enriches each arrangement with live status/summary pulled from
  the right product table, not just the bare Arrangement row.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Arrangements, DebitAccountOpening, PrepaidAccountOpening}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  test "returns Debit and Prepaid arrangements enriched with live status and a real balance summary" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "SearchRollup", last_name: "CustTest#{n}"})
      |> Repo.insert!()

    {:ok, debit} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    {:ok, prepaid} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    rows =
      Arrangements.search(%{search: "SearchRollup"})
      |> Enum.filter(&(&1.customer.customer_id == customer.customer_id))

    debit_row = Enum.find(rows, &(&1.arrangement.product_type == "DEBIT"))
    prepaid_row = Enum.find(rows, &(&1.arrangement.product_type == "PREPAID"))

    assert debit_row
    assert debit_row.arrangement.account_ref == debit.debit_account_id
    assert debit_row.status == "ACTIVE"
    assert debit_row.summary =~ "AED"

    assert prepaid_row
    assert prepaid_row.arrangement.account_ref == prepaid.prepaid_account_id
    assert prepaid_row.status == "ACTIVE"
    assert prepaid_row.summary =~ "AED"
  end

  test "product_type filter narrows to just that product" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "FilterTest", last_name: "CustTest#{n}"})
      |> Repo.insert!()

    {:ok, _debit} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    {:ok, _prepaid} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    rows =
      Arrangements.search(%{search: "FilterTest", product_type: "DEBIT"})
      |> Enum.filter(&(&1.customer.customer_id == customer.customer_id))

    assert length(rows) == 1
    assert hd(rows).arrangement.product_type == "DEBIT"
  end
end
