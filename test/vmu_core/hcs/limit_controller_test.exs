defmodule VmuCore.HCS.LimitControllerTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers the two real gaps found
  and fixed building Way4 parity plan Phase 1 item 2 (2026-07-25):
  DAILY_CAP was schema-valid and documented but had zero enforcement, and
  `can_withdraw_cash` was never read anywhere.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.HCS.{CompanyOnboarding, EmployeeCard, FleetCard, FleetOnboarding, LimitController, SpendingControl}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

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

  defp employee_card_fixture(opts \\ []) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    company_customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "LcTest#{n}",
        customer_tier: "CORPORATE", company_name: "LC Test Co #{n}", registration_number: "REG-LC-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: company_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "lc-test-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: D.new("50000.00")
        },
        company_attrs: %{
          company_code: "LC#{n}", company_name: "LC Test Co #{n}", registration_no: "REG-LC-#{n}",
          liability_model: "CENTRAL", credit_limit: D.new("50000.00")
        }
      })

    employee_customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Emp", last_name: "LcTest#{n}",
        id_type: "PASSPORT", id_number: "EMP-LC-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{employee_card: card}} =
      CompanyOnboarding.add_employee_card(
        company.id,
        %{
          customer_id: employee_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "lc-test-emp-#{n}",
          last_four: "1111", expiry_date: "1230"
        },
        %{
          individual_limit: D.new("5000.00"),
          employee_name: "Emp LcTest#{n}",
          can_withdraw_cash: Keyword.get(opts, :can_withdraw_cash, false)
        }
      )

    {company, card, employee_customer}
  end

  defp employee_account_id(card), do: card.employee_account_id

  defp fleet_card_fixture(opts \\ []) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    company_customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "FcTest#{n}",
        customer_tier: "CORPORATE", company_name: "FC Test Co #{n}", registration_number: "REG-FC-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: company_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "fc-test-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: D.new("50000.00")
        },
        company_attrs: %{
          company_code: "FC#{n}", company_name: "FC Test Co #{n}", registration_no: "REG-FC-#{n}",
          liability_model: "CENTRAL", credit_limit: D.new("50000.00")
        }
      })

    {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-LC-#{n}"})

    {:ok, %{fleet_card: card}} =
      FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{
        individual_limit: D.new("5000.00"),
        can_withdraw_cash: Keyword.get(opts, :can_withdraw_cash, false)
      })

    {company, card}
  end

  describe "check_hcs_limits/5 — cash access" do
    test "a cash transaction is blocked when can_withdraw_cash is false" do
      {_company, card, _cust} = employee_card_fixture(can_withdraw_cash: false)

      assert {:error, :cash_access_blocked} =
               LimitController.check_hcs_limits(employee_account_id(card), D.new("100.00"), :atm, "6011", true)
    end

    test "a cash transaction is allowed when can_withdraw_cash is true" do
      {_company, card, _cust} = employee_card_fixture(can_withdraw_cash: true)

      assert :ok =
               LimitController.check_hcs_limits(employee_account_id(card), D.new("100.00"), :atm, "6011", true)
    end

    test "a non-cash transaction is unaffected by can_withdraw_cash: false" do
      {_company, card, _cust} = employee_card_fixture(can_withdraw_cash: false)

      assert :ok =
               LimitController.check_hcs_limits(employee_account_id(card), D.new("100.00"), :pos, "5411", false)
    end

    test "cash_txn defaults to false when the arg is omitted" do
      {_company, card, _cust} = employee_card_fixture(can_withdraw_cash: false)

      assert :ok = LimitController.check_hcs_limits(employee_account_id(card), D.new("100.00"), :pos, "5411")
    end
  end

  describe "DAILY_CAP enforcement" do
    test "a transaction that would exceed the daily cap is declined" do
      {company, card, _cust} = employee_card_fixture()

      %SpendingControl{}
      |> SpendingControl.changeset(%{
        scope: "EMPLOYEE", company_id: company.id, employee_card_id: card.id,
        control_type: "DAILY_CAP", daily_cap: D.new("200.00"),
        effective_from: Date.utc_today(), status: "ACTIVE",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      account_id = employee_account_id(card)

      assert :ok = LimitController.check_hcs_limits(account_id, D.new("150.00"), :pos, "5411")
      :ok = LimitController.debit_limits(account_id, D.new("150.00"))

      # 150 spent so far today + 60 more would be 210 > 200 cap.
      assert {:error, :daily_cap_exceeded} =
               LimitController.check_hcs_limits(account_id, D.new("60.00"), :pos, "5411")

      # But a smaller amount that stays within the remaining 50 is fine.
      assert :ok = LimitController.check_hcs_limits(account_id, D.new("50.00"), :pos, "5411")
    end

    test "daily_spend rolls over to a fresh amount on a new day, not compounding forever" do
      {company, card, _cust} = employee_card_fixture()

      %SpendingControl{}
      |> SpendingControl.changeset(%{
        scope: "EMPLOYEE", company_id: company.id, employee_card_id: card.id,
        control_type: "DAILY_CAP", daily_cap: D.new("200.00"),
        effective_from: Date.utc_today(), status: "ACTIVE",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      account_id = employee_account_id(card)
      :ok = LimitController.debit_limits(account_id, D.new("150.00"))

      # Simulate the counter being from yesterday.
      Repo.update_all(
        from(ec in EmployeeCard, where: ec.id == ^card.id),
        set: [daily_spend_date: Date.add(Date.utc_today(), -1)]
      )

      # Stale counter means 0 spent today, so 150 more is fine even though
      # 150 (yesterday, now stale) + 150 would have exceeded 200.
      assert :ok = LimitController.check_hcs_limits(account_id, D.new("150.00"), :pos, "5411")
    end

    test "no DAILY_CAP control means no cap enforcement at all" do
      {_company, card, _cust} = employee_card_fixture()
      account_id = employee_account_id(card)

      assert :ok = LimitController.check_hcs_limits(account_id, D.new("4000.00"), :pos, "5411")
    end
  end

  describe "debit_limits/2 maintains daily_spend" do
    test "accumulates within the same day" do
      {_company, card, _cust} = employee_card_fixture()
      account_id = employee_account_id(card)

      :ok = LimitController.debit_limits(account_id, D.new("100.00"))
      :ok = LimitController.debit_limits(account_id, D.new("50.00"))

      reloaded = Repo.get!(EmployeeCard, card.id)
      assert D.equal?(reloaded.daily_spend, D.new("150.00"))
      assert reloaded.daily_spend_date == Date.utc_today()
    end
  end

  describe "fleet cards go through the same generic checks (Way4 Phase 1 item 3)" do
    test "check_hcs_limits/5 resolves a fleet card by account_id when no employee card matches" do
      {_company, card} = fleet_card_fixture()

      assert :ok = LimitController.check_hcs_limits(card.account_id, D.new("100.00"), :pos, "5411")
    end

    test "cash access is enforced for fleet cards exactly like employee cards" do
      {_company, card} = fleet_card_fixture(can_withdraw_cash: false)

      assert {:error, :cash_access_blocked} =
               LimitController.check_hcs_limits(card.account_id, D.new("50.00"), :atm, "6011", true)
    end

    test "debit_limits/2 updates the fleet card's own available_individual and daily_spend" do
      {_company, card} = fleet_card_fixture()

      :ok = LimitController.debit_limits(card.account_id, D.new("100.00"))
      :ok = LimitController.debit_limits(card.account_id, D.new("50.00"))

      reloaded = Repo.get!(FleetCard, card.id)
      assert D.equal?(reloaded.daily_spend, D.new("150.00"))
      assert D.equal?(reloaded.available_individual, D.new("4850.00"))
      assert reloaded.daily_spend_date == Date.utc_today()
    end

    test "credit_limits/2 restores the fleet card's available_individual" do
      {_company, card} = fleet_card_fixture()

      :ok = LimitController.debit_limits(card.account_id, D.new("200.00"))
      :ok = LimitController.credit_limits(card.account_id, D.new("80.00"))

      reloaded = Repo.get!(FleetCard, card.id)
      assert D.equal?(reloaded.available_individual, D.new("4880.00"))
    end

    test "a FLEET-scoped DAILY_CAP control on one fleet card doesn't affect another" do
      {company, card1} = fleet_card_fixture()
      {_company2, card2} = fleet_card_fixture()

      %SpendingControl{}
      |> SpendingControl.changeset(%{
        scope: "FLEET", company_id: company.id, fleet_card_id: card1.id,
        control_type: "DAILY_CAP", daily_cap: D.new("100.00"),
        effective_from: Date.utc_today(), status: "ACTIVE",
        inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

      assert {:error, :daily_cap_exceeded} =
               LimitController.check_hcs_limits(card1.account_id, D.new("150.00"), :pos, "5411")

      # card2 belongs to a different company, so the card1-scoped control
      # never applies to it regardless.
      assert :ok = LimitController.check_hcs_limits(card2.account_id, D.new("150.00"), :pos, "5411")
    end
  end
end
