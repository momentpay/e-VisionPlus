defmodule VmuCore.HCS.DriverAssignmentCommand do
  @moduledoc """
  Driver-to-vehicle assignment history (Way4 parity plan Phase 1 item 3,
  2026-07-25). The "current" assignment for a vehicle is always the
  single row with `unassigned_at == nil` — `assign_driver/3` closes any
  existing open assignment before opening a new one, in the same
  transaction, so a vehicle can never end up with two concurrently-open
  assignments. This is an application-level invariant (not a DB
  constraint), same convention as `FacilityLimitChange` status
  transitions.
  """

  alias VmuCore.{Repo, HCS.DriverAssignment}
  import Ecto.Query

  def current_assignment(vehicle_id) do
    Repo.one(
      from a in DriverAssignment,
        where: a.vehicle_id == ^vehicle_id and is_nil(a.unassigned_at),
        limit: 1
    )
  end

  def history(vehicle_id) do
    Repo.all(
      from a in DriverAssignment,
        where: a.vehicle_id == ^vehicle_id,
        order_by: [desc: a.assigned_at]
    )
  end

  def assign_driver(vehicle_id, driver_name, driver_license_no \\ nil) do
    Repo.transaction(fn ->
      close_current(vehicle_id)

      case %DriverAssignment{}
           |> DriverAssignment.changeset(%{
             vehicle_id: vehicle_id, driver_name: driver_name,
             driver_license_no: driver_license_no, assigned_at: DateTime.utc_now() |> DateTime.truncate(:second)
           })
           |> Repo.insert() do
        {:ok, assignment} -> assignment
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  def unassign_driver(vehicle_id) do
    case close_current(vehicle_id) do
      {0, _} -> {:error, :no_active_assignment}
      {_n, _} -> :ok
    end
  end

  defp close_current(vehicle_id) do
    Repo.update_all(
      from(a in DriverAssignment, where: a.vehicle_id == ^vehicle_id and is_nil(a.unassigned_at)),
      set: [unassigned_at: DateTime.utc_now() |> DateTime.truncate(:second)]
    )
  end
end
