defmodule VmuCore.CTA.Card do
  @moduledoc """
  First-class card (plastic generation) entity (CTA-P1.2).

  One row per physical/virtual card issued against an account. A replacement
  or renewal is a NEW row (incremented `generation`, `replaces_card_id`
  pointing at the prior one) — never a mutation of the old plastic, so the
  full issuance history survives (FR-024).

  `status` is driven only through `VmuCore.CTA.Cards.transition/3`
  (validated by `CardStateMachine`); never write it directly.

  Per ADR-CTA1 the account row keeps denormalized current-card fields for the
  auth hot path; `Cards` keeps them in sync for the ACTIVE card.

  ## Koṣa domain-model alignment (2026-07-28)

  This schema is already the concrete "Card" branch of Koṣa's Payment
  Instrument layer (`docs/cms/core-domain-new-docs.md`) — the
  `account_id`/`debit_account_id`/`prepaid_account_id` three-way
  polymorphism *is* "Payment Instrument → Card → (Credit, Debit,
  Prepaid, others)". No new table needed for that: a `PaymentInstrument`
  umbrella above `cta_cards` is deliberately deferred until a second
  real instrument type (QR/UPI/wallet token) actually exists to
  justify it — see the architecture doc's decision log. This module's
  `instrument_product_type/1` is the one small, real piece added now:
  a named, reusable way to ask "which product does this card belong
  to" instead of every caller re-deriving it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.CTA.CardStateMachine

  @primary_key {:card_id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @card_types    ~w[PRIMARY SUPPLEMENTARY VIRTUAL]
  @block_reasons ~w[LOST STOLEN FRAUD DAMAGED ADMIN]

  schema "cta_cards" do
    field :account_id,        :binary_id
    # Way4 parity plan Phase 1 item 4 (Debit, 2026-07-26) — a debit card
    # points here instead of :account_id, since CMS.Account requires a
    # credit_limit a debit account doesn't have.
    field :debit_account_id,  :binary_id
    # Way4 parity plan Phase 1 item 5 (Prepaid, 2026-07-27) — a prepaid
    # card points here instead. Exactly one of account_id/
    # debit_account_id/prepaid_account_id must be set (enforced in
    # changeset/2, not a DB CHECK — same convention as
    # hcs_spending_controls.fleet_card_id/employee_card_id).
    field :prepaid_account_id, :binary_id
    field :pan_token,         :string
    field :last_four,         :string
    field :expiry,            :string
    field :emboss_name,       :string
    field :card_type,         :string, default: "PRIMARY"
    field :status,            :string, default: "INACTIVE"
    field :block_reason,      :string
    field :generation,        :integer, default: 1
    field :replaces_card_id,  :binary_id
    field :activation_method, :string
    field :dispatch_ref,      :string
    field :ecom_enabled,        :boolean
    field :atm_enabled,         :boolean
    field :contactless_enabled, :boolean
    field :intl_enabled,        :boolean
    field :issued_at,    :utc_datetime
    field :activated_at, :utc_datetime
    field :blocked_at,   :utc_datetime
    field :expired_at,   :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[pan_token card_type status generation]a
  @optional ~w[account_id debit_account_id prepaid_account_id last_four expiry emboss_name block_reason replaces_card_id
               activation_method dispatch_ref ecom_enabled atm_enabled
               contactless_enabled intl_enabled issued_at activated_at
               blocked_at expired_at]a

  def changeset(card, attrs) do
    card
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:card_type, @card_types)
    |> validate_inclusion(:status, CardStateMachine.states())
    |> validate_inclusion(:block_reason, @block_reasons)
    |> validate_length(:pan_token, is: 64)
    |> validate_length(:last_four, is: 4)
    |> validate_number(:generation, greater_than: 0)
    |> validate_exactly_one_account_ref()
    |> unique_constraint(:pan_token,
         name: :cta_cards_active_pan_token_index,
         message: "another live card already holds this PAN")
  end

  defp validate_exactly_one_account_ref(changeset) do
    refs =
      [:account_id, :debit_account_id, :prepaid_account_id]
      |> Enum.map(&get_field(changeset, &1))
      |> Enum.reject(&is_nil/1)

    case length(refs) do
      0 ->
        add_error(changeset, :account_id,
          "one of account_id/debit_account_id/prepaid_account_id is required")

      1 ->
        changeset

      _ ->
        add_error(changeset, :account_id,
          "exactly one of account_id/debit_account_id/prepaid_account_id must be set")
    end
  end

  def card_types,    do: @card_types
  def block_reasons, do: @block_reasons

  @doc """
  Which product this card belongs to, derived from which of the three
  polymorphic refs is set (Koṣa domain-model alignment, 2026-07-28) —
  no separate field to keep in sync, no separate query.
  """
  @spec instrument_product_type(t()) :: :CREDIT | :DEBIT | :PREPAID
  def instrument_product_type(%__MODULE__{account_id: id}) when not is_nil(id), do: :CREDIT
  def instrument_product_type(%__MODULE__{debit_account_id: id}) when not is_nil(id), do: :DEBIT
  def instrument_product_type(%__MODULE__{prepaid_account_id: id}) when not is_nil(id), do: :PREPAID
end
