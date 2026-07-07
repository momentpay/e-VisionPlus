defmodule VmuCore.FAS.PendingHold do
  @moduledoc "Ecto schema for the fas_pending_holds table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fas_pending_holds" do
    field :fas_authorization_id, :binary_id
    field :account_id,           :binary_id
    field :hold_amount,          :decimal
    field :hold_type,            :string, default: "standard"
    field :expires_at,           :utc_datetime
    field :cleared_at,           :utc_datetime
    field :reversal_at,          :utc_datetime

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @valid_hold_types ~w[standard hotel fuel preauth incremental]

  @required ~w[fas_authorization_id account_id hold_amount hold_type expires_at]a
  @optional ~w[cleared_at reversal_at]a

  def changeset(hold, attrs) do
    hold
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:hold_type, @valid_hold_types)
    |> validate_number(:hold_amount, greater_than: Decimal.new(0))
  end

  @doc "Mark this hold as cleared by settlement."
  def clear_changeset(hold, cleared_at \\ DateTime.utc_now()) do
    hold
    |> change(cleared_at: DateTime.truncate(cleared_at, :second))
  end

  @doc "Mark this hold as released by reversal."
  def reverse_changeset(hold, reversal_at \\ DateTime.utc_now()) do
    hold
    |> change(reversal_at: DateTime.truncate(reversal_at, :second))
  end

  @doc "Adjust the hold amount (incremental trim / completion trim)."
  def set_hold_amount_changeset(hold, new_amount) do
    hold
    |> change(hold_amount: new_amount)
    |> validate_number(:hold_amount, greater_than: Decimal.new(0))
  end
end
