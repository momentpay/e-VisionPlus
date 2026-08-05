defmodule VmuCore.GL.InstitutionResolverHcsTest do
  @moduledoc """
  HCS product resolution (added 2026-08-05).

  HCS cards are an **overlay** on `cms_accounts` rather than a product table of
  their own: `HCS.CompanyOnboarding` and `HCS.FleetOnboarding` each provision a
  real `CMS.Account` and the HCS card row stores its id. So institution
  resolution is unchanged — it still comes from `cms_accounts` — and only the
  product label refines.

  The risk this covers is a relabel that reaches too far. Every credit account
  in the system flows through the same code path, and labelling an ordinary
  consumer account `HCS_*` would post it to the corporate receivable.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.GL.InstitutionResolver
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.CMS.Account
  alias VmuCore.HCS.{Company, EmployeeCard}
  alias Decimal, as: D

  setup do
    InstitutionResolver.reset()
    on_exit(&InstitutionResolver.reset/0)
    :ok
  end

  defp institution do
    n = System.unique_integer([:positive])
    sys_id = "R#{100 + rem(n, 900)}"
    bank_id = "S#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "t"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "t"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "t"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
    })
    |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = institution()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Res", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "RES-#{n}"
      })
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id, pan_token: "res-pan-#{n}",
        last_four: "4321", expiry_date: "1230",
        credit_limit: D.new("10000.00"), open_to_buy: D.new("10000.00")
      })
      |> Repo.insert!()

    {account, sys_id, bank_id}
  end

  defp company_fixture do
    n = System.unique_integer([:positive])

    %Company{}
    |> Company.changeset(%{
      company_code: "CO#{n}", company_name: "Test Co #{n}", registration_no: "REG-#{n}",
      liability_model: "CENTRAL", credit_limit: D.new("100000.00"),
      available_limit: D.new("100000.00")
    })
    |> Repo.insert!()
  end

  defp claim_as_employee_card(company, account) do
    n = System.unique_integer([:positive])

    %EmployeeCard{}
    |> EmployeeCard.changeset(%{
      company_id: company.id, employee_account_id: account.account_id,
      employee_name: "Emp #{n}", employee_id: "E#{n}",
      individual_limit: D.new("5000.00"), available_individual: D.new("5000.00")
    })
    |> Repo.insert!()
  end

  test "an ordinary credit account still resolves as CREDIT" do
    {account, _sys, _bank} = account_fixture()

    assert {:ok, "CREDIT"} = InstitutionResolver.resolve_product(account.account_id)
    assert :none = InstitutionResolver.hcs_overlay(account.account_id)
  end

  test "an account claimed by hcs_employee_cards resolves as HCS_CORPORATE" do
    {account, _sys, _bank} = account_fixture()
    company = company_fixture()

    claim_as_employee_card(company, account)

    InstitutionResolver.reset()

    assert {:ok, "HCS_CORPORATE"} = InstitutionResolver.resolve_product(account.account_id)
    assert {:ok, "HCS_CORPORATE"} = InstitutionResolver.hcs_overlay(account.account_id)
  end

  test "the institution is unchanged by the relabel — it still comes from cms_accounts" do
    {account, sys_id, bank_id} = account_fixture()
    company = company_fixture()

    claim_as_employee_card(company, account)

    InstitutionResolver.reset()

    # Resolvable under the HCS label...
    assert {:ok, {^sys_id, ^bank_id}} =
             InstitutionResolver.resolve(account.account_id, "HCS_CORPORATE")

    # ...and under CREDIT too, because both read the same `cms_accounts` row.
    # The cache keys on the source table, so one must not poison the other.
    assert {:ok, {^sys_id, ^bank_id}} = InstitutionResolver.resolve(account.account_id, "CREDIT")
  end

  test "one account becoming HCS does not relabel any other account" do
    {hcs_account, _, _} = account_fixture()
    {plain_account, _, _} = account_fixture()
    company = company_fixture()

    claim_as_employee_card(company, hcs_account)

    InstitutionResolver.reset()

    assert {:ok, "HCS_CORPORATE"} = InstitutionResolver.resolve_product(hcs_account.account_id)
    assert {:ok, "CREDIT"} = InstitutionResolver.resolve_product(plain_account.account_id)
  end

  test "the negative overlay result is cached, so non-HCS accounts do not re-query" do
    {account, _, _} = account_fixture()

    assert :none = InstitutionResolver.hcs_overlay(account.account_id)

    # Insert an HCS claim *after* the negative was cached. The cached answer
    # must win — this documents that the overlay cache is only invalidated by
    # `reset/0`, which is what makes it safe on the posting hot path.
    company = company_fixture()

    claim_as_employee_card(company, account)

    assert :none = InstitutionResolver.hcs_overlay(account.account_id)

    InstitutionResolver.reset()
    assert {:ok, "HCS_CORPORATE"} = InstitutionResolver.hcs_overlay(account.account_id)
  end
end
