defmodule VmuCore.HCS.FleetOnboardingTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 3
  (2026-07-25) — fleet vehicle onboarding + fleet card issuance.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.HCS.{CompanyOnboarding, FleetCard, FleetOnboarding, Vehicle}
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

  defp company_fixture(credit_limit \\ D.new("50000.00")) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    company_customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "FleetTest#{n}",
        customer_tier: "CORPORATE", company_name: "Fleet Test Co #{n}", registration_number: "REG-FL-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: company_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "fleet-test-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: credit_limit
        },
        company_attrs: %{
          company_code: "FL#{n}", company_name: "Fleet Test Co #{n}", registration_no: "REG-FL-#{n}",
          liability_model: "CENTRAL", credit_limit: credit_limit
        }
      })

    company
  end

  describe "add_vehicle/2" do
    test "creates a vehicle under the company" do
      company = company_fixture()

      assert {:ok, %Vehicle{} = vehicle} =
               FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-1234", vin: "VIN0001"})

      assert vehicle.company_id == company.id
      assert vehicle.status == "ACTIVE"
    end

    test "rejects a duplicate VIN within the same company" do
      company = company_fixture()

      assert {:ok, _} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-1", vin: "DUPVIN"})
      assert {:error, changeset} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-2", vin: "DUPVIN"})
      # Ecto's unique_constraint/2 attaches the error to the first field of
      # the composite list ([:company_id, :vin]) by default, not to :vin.
      assert %{company_id: ["has already been taken"]} = errors_on(changeset)
    end
  end

  describe "add_fleet_card/3" do
    test "issues a fleet card and creates its CMS account" do
      company = company_fixture()
      {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-9999"})

      assert {:ok, %{fleet_card: card, account: account}} =
               FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("5000.00")})

      assert card.vehicle_id == vehicle.id
      assert card.account_id == account.account_id
      assert D.equal?(card.available_individual, D.new("5000.00"))
      assert card.status == "ACTIVE"
    end

    test "rejects issuance against a non-ACTIVE vehicle" do
      company = company_fixture()
      {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-0001", status: "RETIRED"})

      assert {:error, :vehicle_not_active} =
               FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("1000.00")})
    end

    test "rejects a limit that would exceed the remaining company pool" do
      company = company_fixture(D.new("10000.00"))
      {:ok, vehicle1} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-A"})
      {:ok, vehicle2} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-B"})

      assert {:ok, _} = FleetOnboarding.add_fleet_card(company.id, vehicle1.id, %{individual_limit: D.new("7000.00")})

      assert {:error, :individual_limit_exceeds_company_pool} =
               FleetOnboarding.add_fleet_card(company.id, vehicle2.id, %{individual_limit: D.new("4000.00")})
    end

    test "pool check sums existing employee cards together with fleet cards" do
      company = company_fixture(D.new("10000.00"))

      # Reuse the company's own parameter hierarchy via its parent account.
      parent_account = Repo.get!(VmuCore.CMS.Account, company.parent_account_id)

      employee_customer =
        %Customer{}
        |> Customer.changeset(%{
          sys_id: parent_account.sys_id, bank_id: parent_account.bank_id,
          first_name: "Emp", last_name: "FleetPoolTest",
          id_type: "PASSPORT", id_number: "EMP-FL-#{System.unique_integer([:positive])}"
        })
        |> Repo.insert!()

      {:ok, %{employee_card: _emp_card}} =
        CompanyOnboarding.add_employee_card(
          company.id,
          %{
            customer_id: employee_customer.customer_id, sys_id: parent_account.sys_id,
            bank_id: parent_account.bank_id, logo_id: parent_account.logo_id,
            block_id: parent_account.block_id, pan_token: "fleet-pool-emp-#{System.unique_integer([:positive])}",
            last_four: "2222", expiry_date: "1230"
          },
          %{individual_limit: D.new("6000.00"), employee_name: "Emp FleetPoolTest"}
        )

      {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-POOL"})

      # 6000 (employee) + 5000 (proposed fleet) = 11000 > 10000 pool.
      assert {:error, :individual_limit_exceeds_company_pool} =
               FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("5000.00")})

      assert {:ok, _} =
               FleetOnboarding.add_fleet_card(company.id, vehicle.id, %{individual_limit: D.new("3000.00")})
    end
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
