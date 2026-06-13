defmodule VmuCore.HCS.PaymentSweep do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_payment_sweeps" do
    field :company_id,          :integer
    field :sweep_date,          :date
    field :total_swept,         :decimal, default: 0
    field :employee_card_count, :integer, default: 0
    field :status,              :string, default: "PENDING"
    field :gl_entry_id,         :integer
    field :inserted_at,         :utc_datetime

    has_many :sweep_lines, VmuCore.HCS.PaymentSweepLine, foreign_key: :sweep_id
  end

  def changeset(sweep, attrs) do
    sweep
    |> cast(attrs, [:company_id, :sweep_date, :total_swept, :employee_card_count,
                    :status, :gl_entry_id, :inserted_at])
    |> validate_required([:company_id, :sweep_date])
    |> validate_inclusion(:status, ~w(PENDING COMPLETED PARTIAL FAILED))
  end
end

defmodule VmuCore.HCS.PaymentSweepLine do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_payment_sweep_lines" do
    field :sweep_id,         :integer
    field :employee_card_id, :integer
    field :swept_amount,     :decimal
    field :status,           :string, default: "PENDING"
    field :inserted_at,      :utc_datetime
  end

  def changeset(line, attrs) do
    line
    |> cast(attrs, [:sweep_id, :employee_card_id, :swept_amount, :status, :inserted_at])
    |> validate_required([:sweep_id, :employee_card_id, :swept_amount])
  end
end
