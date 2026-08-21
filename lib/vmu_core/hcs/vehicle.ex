defmodule VmuCore.HCS.Vehicle do
  @moduledoc """
  Fleet vehicle master (Way4 parity plan Phase 1 item 3, 2026-07-25).
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_vehicles" do
    field :company_id,   :integer
    field :vin,          :string
    field :plate_number, :string
    field :make,         :string
    field :model,        :string
    field :year,         :integer
    field :status,       :string, default: "ACTIVE"

    belongs_to :company, VmuCore.HCS.Company, define_field: false

    timestamps(type: :utc_datetime)
  end

  @valid_statuses ~w(ACTIVE INACTIVE RETIRED)

  def changeset(vehicle, attrs) do
    vehicle
    |> cast(attrs, [:company_id, :vin, :plate_number, :make, :model, :year, :status])
    |> validate_required([:company_id, :plate_number])
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint([:company_id, :vin])
  end
end
