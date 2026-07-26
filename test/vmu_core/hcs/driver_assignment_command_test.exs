defmodule VmuCore.HCS.DriverAssignmentCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 3
  (2026-07-25) — covers the "only one open assignment per vehicle" invariant.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.HCS.{CompanyOnboarding, DriverAssignmentCommand, FleetOnboarding}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp vehicle_fixture do
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
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "DriverTest#{n}",
        customer_tier: "CORPORATE", company_name: "Driver Test Co #{n}", registration_number: "REG-DR-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: company_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "driver-test-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: D.new("50000.00")
        },
        company_attrs: %{
          company_code: "DR#{n}", company_name: "Driver Test Co #{n}", registration_no: "REG-DR-#{n}",
          liability_model: "CENTRAL", credit_limit: D.new("50000.00")
        }
      })

    {:ok, vehicle} = FleetOnboarding.add_vehicle(company.id, %{plate_number: "DXB-DRV-#{n}"})
    vehicle
  end

  test "assign_driver/3 opens a current assignment" do
    vehicle = vehicle_fixture()

    assert {:ok, assignment} = DriverAssignmentCommand.assign_driver(vehicle.id, "Ali Hassan")
    assert is_nil(assignment.unassigned_at)
    assert DriverAssignmentCommand.current_assignment(vehicle.id).id == assignment.id
  end

  test "assigning a new driver closes the previous open assignment" do
    vehicle = vehicle_fixture()

    {:ok, first} = DriverAssignmentCommand.assign_driver(vehicle.id, "Ali Hassan")
    {:ok, second} = DriverAssignmentCommand.assign_driver(vehicle.id, "Omar Khalid")

    reloaded_first = Repo.get!(VmuCore.HCS.DriverAssignment, first.id)
    assert not is_nil(reloaded_first.unassigned_at)

    current = DriverAssignmentCommand.current_assignment(vehicle.id)
    assert current.id == second.id

    history = DriverAssignmentCommand.history(vehicle.id)
    assert length(history) == 2
  end

  test "unassign_driver/1 closes the open assignment" do
    vehicle = vehicle_fixture()
    {:ok, _} = DriverAssignmentCommand.assign_driver(vehicle.id, "Ali Hassan")

    assert :ok = DriverAssignmentCommand.unassign_driver(vehicle.id)
    assert is_nil(DriverAssignmentCommand.current_assignment(vehicle.id))
  end

  test "unassign_driver/1 errors when there is no active assignment" do
    vehicle = vehicle_fixture()
    assert {:error, :no_active_assignment} = DriverAssignmentCommand.unassign_driver(vehicle.id)
  end

  test "a vehicle never has two concurrently-open assignments" do
    vehicle = vehicle_fixture()
    {:ok, _} = DriverAssignmentCommand.assign_driver(vehicle.id, "Driver A")
    {:ok, _} = DriverAssignmentCommand.assign_driver(vehicle.id, "Driver B")
    {:ok, _} = DriverAssignmentCommand.assign_driver(vehicle.id, "Driver C")

    open_count =
      DriverAssignmentCommand.history(vehicle.id)
      |> Enum.count(&is_nil(&1.unassigned_at))

    assert open_count == 1
  end
end
