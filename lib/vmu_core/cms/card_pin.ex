defmodule VmuCore.CMS.CardPin do
  @moduledoc """
  Ecto schema for `cms_card_pins` (FAS-P7 7E; redesigned Way4 parity plan
  Phase 0 item 7, 2026-07-24).

  `reference_pin_lmk` is the LMK-encrypted reference PIN block payShield's
  BE command ("Verify an Interchange PIN Using the Comparison Method")
  compares an incoming DE52 PIN block against — an opaque value, useless
  without the LMK that lives inside the HSM. This replaces the previous
  `pin_hash`/`pin_salt` design, which decoded the ISO PIN block to
  plaintext digits in application code before comparing — not how any
  real HSM/PCI-compliant PIN flow works. See `VmuCore.FAS.HSM`'s
  moduledoc and `VmuCore.FAS.HSM.ProductionHSM`'s `verify_pin/3`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "cms_card_pins" do
    field :pan_token,         :string
    field :reference_pin_lmk, :string
    field :try_counter,       :integer, default: 0
    field :pin_locked_at,     :utc_datetime

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w[pan_token reference_pin_lmk]a
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

  @doc "Set/replace the stored reference PIN (self-service change)."
  def set_reference_changeset(pin, reference_pin_lmk) do
    change(pin, reference_pin_lmk: reference_pin_lmk, try_counter: 0, pin_locked_at: nil)
  end
end
