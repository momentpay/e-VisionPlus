defmodule VmuCore.COL.DpdBucketHistory do
  @moduledoc """
  Ecto schema for `col_dpd_bucket_history` (FR-COL-025) — one row per real
  DPD bucket transition (never per EOD run; most runs are a no-op for most
  accounts). Written by `VmuCore.CMS.EOD.AgeBucketsJob` at the same point
  it already detects `account.delinquency_bucket != new_dpd`. The only
  source of bucket-transition history in the system — `cms_accounts.
  delinquency_bucket` itself is a single mutable field with no trail.

  Consumed by `VmuCore.COL.CollectionsMi` for roll-rate/cure-rate
  reporting. Only has data from whenever this table started recording
  forward — no historical backfill exists (there was nothing to backfill
  from), which `CollectionsMi`/the admin screen surface honestly rather
  than guessing at pre-existing transitions.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "col_dpd_bucket_history" do
    field :account_id, :binary_id
    field :eod_date,   :date
    field :old_bucket, :integer
    field :new_bucket, :integer

    timestamps(updated_at: false)
  end

  @required [:account_id, :eod_date, :old_bucket, :new_bucket]

  def changeset(row, attrs) do
    row
    |> cast(attrs, @required)
    |> validate_required(@required)
  end

  @type t :: %__MODULE__{}
end
