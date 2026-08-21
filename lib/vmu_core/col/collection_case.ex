defmodule VmuCore.COL.CollectionCase do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:case_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[OPEN PROMISED WORKOUT AGENCY WRITTEN_OFF RECOVERED CLOSED]
  @valid_promise_statuses ~w[PENDING KEPT BROKEN]

  schema "col_collection_cases" do
    field :account_id,        :binary_id
    field :dpd_bucket,        :integer
    field :outstanding_amount,:decimal
    field :status,            :string, default: "OPEN"
    field :assigned_to,       :string
    field :promise_date,      :date
    field :promise_amount,    :decimal
    field :promise_status,    :string
    field :promise_logged_at, :utc_datetime
    field :workout_plan_id,   :binary_id
    field :write_off_date,    :date
    field :write_off_amount,  :decimal

    timestamps()
  end

  def changeset(c, attrs) do
    c
    |> cast(attrs, [:account_id, :dpd_bucket, :outstanding_amount, :status,
                    :assigned_to, :promise_date, :promise_amount, :promise_status,
                    :promise_logged_at, :write_off_date, :write_off_amount])
    |> validate_required([:account_id, :dpd_bucket, :outstanding_amount])
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:promise_status, @valid_promise_statuses)
  end
end
