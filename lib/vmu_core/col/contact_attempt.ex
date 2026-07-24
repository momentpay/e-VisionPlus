defmodule VmuCore.COL.ContactAttempt do
  @moduledoc """
  One logged collection contact attempt (COL-P2, FR-COL-005). Append-only —
  no `updated_at`, matching `VmuCore.FAS.ExceptionQueue`'s log-table shape.
  Written by `VmuCore.COL.ContactHistory`; never inserted directly.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @channels ~w[sms email letter courier registered_mail call]

  schema "col_contact_attempts" do
    field :account_id,   :binary_id
    field :channel,      :string
    field :dpd_bucket,   :integer
    field :outcome,      :string
    field :notes,        :string
    field :attempted_by, :string

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w[account_id channel attempted_by]a
  @optional ~w[dpd_bucket outcome notes]a

  def changeset(attempt, attrs) do
    attempt
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:channel, @channels)
    |> validate_length(:notes, max: 500)
  end

  def channels, do: @channels
end
