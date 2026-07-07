defmodule VmuCore.CMS.CardPin do
  @moduledoc "Ecto schema for `cms_card_pins` (FAS-P7 7E)."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cms_card_pins" do
    field :pan_token,    :string
    field :pin_hash,     :string
    field :pin_salt,     :string
    field :try_counter,  :integer, default: 0
    field :pin_locked_at, :utc_datetime

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w[pan_token pin_hash pin_salt]a
  @optional ~w[try_counter pin_locked_at]a

  def changeset(pin, attrs) do
    pin
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint(:pan_token)
    |> validate_number(:try_counter, greater_than_or_equal_to: 0)
  end

  @doc "Reset try counter to 0 after a successful PIN verification."
  def reset_tries_changeset(pin) do
    change(pin, try_counter: 0)
  end

  @doc "Increment try counter after a wrong PIN."
  def increment_tries_changeset(pin, new_count) do
    change(pin, try_counter: new_count)
  end

  @doc "Lock the card PIN after exceeding max tries."
  def lock_changeset(pin, locked_at) do
    change(pin, try_counter: pin.try_counter + 1,
                pin_locked_at: DateTime.truncate(locked_at, :second))
  end
end
