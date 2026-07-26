defmodule VmuCore.HCS.FleetReportTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 3
  (2026-07-25) — fleet spend reporting by vehicle and by currently-assigned
  driver.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.LedgerEntry
  alias VmuCore.HCS.{CompanyOnboarding, DriverAssignmentCommand, FleetOnboarding, FleetReport}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp company_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    company_customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "ReportTest#{n}",
        customer_tier: "CORPORATE", company_name: "Report Test Co #{n}", registration_number: "REG-RP-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: company_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "report-test-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: D.new("50000.00")
        },
        company_attrs: %{
          company_code: "RP#{n}", company_name: "Report Test Co #{n}", registration_no: "REG-RP-#{n}",
          liability_model: "CENTRAL", credit_limit: D.new("50000.00")
        }
      })

    company
  end

  defp post_purchase(account_id, amount, posting_date) do
    entry =
      %LedgerEntry{}
      |> LedgerEntry.changeset(%{
        account_id: account_id, idempotency_key: "fleet-rpt-#{System.unique_integer([:positive])}",
        transaction_code: "PURCHASE", dr_amount: amount, cr_amount: amount,
        gl_account_dr: "1000", gl_account_cr: "4000",
        posting_date: posting_date, value_date: posting_date
      })
      |> Repo.insert!()

    # inserted_at is set to real "now" by timestamps() regardless of
    # posting_date — backdate it directly so period-range filtering
    # (which reads inserted_at, matching ConsolidatedStatementGenerator's
    # own convention) can be exercised with an out-of-window entry.
    if Date.diff(Date.utc_today(), posting_date) > 0 do
      backdated = NaiveDateTime.new!(posting_date, ~T[12:00:00])
      Repo.update_all(from(l in LedgerEntry, where: l.entry_id == ^entry.entry_id),
        set: [inserted_at: backdated])
    end

    entry
  end

  test "spend_by_vehicle/3 sums ledger purchases within the period per vehicle" do
    company = company_fixture()
    {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-RPT-1"})
    {:ok, %{fleet_card: card}} =
      FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("5000.00")})

    today = Date.utc_today()
    post_purchase(card.account_id, D.new("120.00"), today)
    post_purchase(card.account_id, D.new("30.00"), today)
    # Outside the reporting window — must not be counted.
    post_purchase(card.account_id, D.new("999.00"), Date.add(today, -60))

    [row] = FleetReport.spend_by_vehicle(company.id, Date.add(today, -7), today)
    assert row.vehicle_id == vehicle.id
    assert D.equal?(row.spend, D.new("150.00"))
  end

  test "total_spend/3 sums across all of a company's fleet cards" do
    company = company_fixture()
    {:ok, v1} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-RPT-2"})
    {:ok, v2} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-RPT-3"})
    {:ok, %{fleet_card: c1}} = FleetOnboarding.add_fleet_card(company.id, v1.id, %{individual_limit: D.new("5000.00")})
    {:ok, %{fleet_card: c2}} = FleetOnboarding.add_fleet_card(company.id, v2.id, %{individual_limit: D.new("5000.00")})

    today = Date.utc_today()
    post_purchase(c1.account_id, D.new("100.00"), today)
    post_purchase(c2.account_id, D.new("50.00"), today)

    total = FleetReport.total_spend(company.id, Date.add(today, -1), today)
    assert D.equal?(total, D.new("150.00"))
  end

  test "spend_by_driver/3 attributes 100% of a vehicle's period spend to the currently assigned driver" do
    company = company_fixture()
    {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-RPT-4"})
    {:ok, %{fleet_card: card}} =
      FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("5000.00")})

    today = Date.utc_today()
    post_purchase(card.account_id, D.new("80.00"), today)

    {:ok, _} = DriverAssignmentCommand.assign_driver(vehicle.id, "Driver One")
    {:ok, _} = DriverAssignmentCommand.assign_driver(vehicle.id, "Driver Two")

    [row] = FleetReport.spend_by_driver(company.id, Date.add(today, -1), today)
    assert row.driver_name == "Driver Two"
    assert D.equal?(row.spend, D.new("80.00"))
  end

  test "spend_by_driver/3 groups an unassigned vehicle under UNASSIGNED" do
    company = company_fixture()
    {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-RPT-5"})
    {:ok, %{fleet_card: card}} =
      FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("5000.00")})

    today = Date.utc_today()
    post_purchase(card.account_id, D.new("40.00"), today)

    [row] = FleetReport.spend_by_driver(company.id, Date.add(today, -1), today)
    assert row.driver_name == "UNASSIGNED"
    assert D.equal?(row.spend, D.new("40.00"))
  end
end
