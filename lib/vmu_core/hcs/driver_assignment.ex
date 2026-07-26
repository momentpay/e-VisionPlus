defmodule VmuCore.HCS.DriverAssignment do
  @moduledoc """
  Driver-to-vehicle assignment history (Way4 parity plan Phase 1 item 3,
  2026-07-25). The current assignment for a vehicle is the row with
  `unassigned_at == nil` — enforced by `DriverAssignmentCommand`, not a DB
  constraint (same "invariant lives in the command module" convention as
  `FacilityLimitChange`'s status transitions).
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_driver_assignments" do
    field :vehicle_id,        :integer
    field :driver_name,       :string
    field :driver_license_no, :string
    field :assigned_at,       :utc_datetime
    field :unassigned_at,     :utc_datetime

    belongs_to :vehicle, VmuCore.HCS.Vehicle, define_field: false

    timestamps(type: :utc_datetime)
  end

  def changeset(assignment, attrs) do
    assignment
    |> cast(attrs, [:vehicle_id, :driver_name, :driver_license_no, :assigned_at, :unassigned_at])
    |> validate_required([:vehicle_id, :driver_name, :assigned_at])
  end
end
