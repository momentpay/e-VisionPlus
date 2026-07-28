defmodule VmuCore.CMS.EOD.LockAccountsJobTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Regression test for a real bug
  found live 2026-07-28 (Card Products UX Parity Phase 3 scoping):
  `HCS.CompanyOnboarding`'s EMPLOYEE_CARD/CORPORATE_PARENT sub-accounts
  were indistinguishable from real revolving-credit accounts to the EOD
  sweep, because `account_type` was passed into `CMS.Account.changeset/2`
  but silently dropped (not a schema field) — meaning they were already
  being locked and swept into interest accrual/statement generation.
  Fixed by persisting `account_type` and filtering both `EodSchedulerJob`
  and this job's own query by `account_type == "CREDIT"`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CMS.EOD.LockAccountsJob
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp account_fixture(account_type) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Lock", last_name: "JobTest#{n}"})
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
      pan_token: "lockjob-test-#{n}", last_four: "0000", expiry_date: "1230",
      credit_limit: D.new("1000.00"), cycle_code: 15, account_status: "ACTIVE",
      account_type: account_type
    })
    |> Repo.insert!()
  end

  test "excludes EMPLOYEE_CARD/CORPORATE_PARENT accounts from being locked on their cycle_code" do
    # Deliberately no real CREDIT account in this test — Oban runs
    # `testing: :inline` in this environment, so LockAccountsJob's own
    # AccrueInterestJob enqueue would execute synchronously and requires
    # a full ParameterEngine cache setup this regression test doesn't
    # need; the fix under test is the exclusion itself, which is fully
    # exercised by accounts_to_lock staying empty for these account_types.
    employee_account = account_fixture("EMPLOYEE_CARD")
    corporate_parent_account = account_fixture("CORPORATE_PARENT")

    LockAccountsJob.perform(%Oban.Job{args: %{"eod_date" => Date.to_iso8601(Date.utc_today()), "cycle_code" => 15}})

    updated_employee = Repo.get!(Account, employee_account.account_id)
    updated_corporate = Repo.get!(Account, corporate_parent_account.account_id)

    assert updated_employee.account_status == "ACTIVE"
    assert updated_corporate.account_status == "ACTIVE"
  end
end
