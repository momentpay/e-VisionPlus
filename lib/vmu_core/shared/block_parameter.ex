defmodule VmuCore.Shared.BlockParameter do
  @moduledoc """
  VisionPlus BLOCK control record — sub-product tier overrides.

  Hierarchy: SYS → BANK → LOGO → BLOCK

  A BLOCK represents a product tier within a LOGO (e.g. Gold / Platinum / Basic
  within a single Visa Credit programme). Every field is nullable; a nil value
  means the ParameterEngine falls back to the parent LOGO value.

  ## Override semantics

  Only populate a field when this block's behaviour must differ from the LOGO.
  The ParameterEngine resolves:

      Block.apr_percentage            (if non-nil)
        → Logo.purchase_apr           (fallback)
        → SysParameter global default (final fallback)

  ## Common use-cases

  - Gold tier has lower annual fee than Platinum within the same BIN range
  - Corporate block disables international transactions by default
  - Basic tier has a lower default credit limit than the standard block
  - Premium block allows overlimit; basic block does not
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "block_parameters" do
    field :block_id, :string, primary_key: true
    field :sys_id,   :string, primary_key: true
    field :bank_id,  :string, primary_key: true
    field :logo_id,  :string, primary_key: true

    # Identity
    field :description, :string

    # ── Rate overrides ───────────────────────────────────────────────────────
    field :apr_percentage,           :decimal
    field :cash_apr_percentage,      :decimal
    field :cash_advance_fee_percent, :decimal

    # ── Fee overrides ────────────────────────────────────────────────────────
    field :annual_fee,    :decimal
    field :late_fee,      :decimal
    field :overlimit_fee, :decimal

    # ── Billing overrides ────────────────────────────────────────────────────
    field :overlimit_allowed,       :boolean
    field :min_payment_pct,         :decimal
    field :min_payment_floor,       :decimal
    field :min_payment_calculation, :string
    field :grace_days,              :integer
    field :payment_due_days,        :integer
    field :cash_limit_pct,          :decimal
    field :statement_cycle_days,    :integer

    # ── Credit limit overrides ───────────────────────────────────────────────
    field :credit_limit_default, :decimal
    field :credit_limit_min,     :decimal
    field :credit_limit_max,     :decimal

    # ── Auth channel overrides ───────────────────────────────────────────────
    field :ecom_enabled,        :boolean
    field :atm_enabled,         :boolean
    field :intl_enabled,        :boolean
    field :contactless_enabled, :boolean
    field :recurring_enabled,   :boolean
    field :moto_enabled,        :boolean

    # ── STIP overrides ───────────────────────────────────────────────────────
    field :stip_enabled,     :boolean
    field :stip_floor_limit, :decimal
    field :stip_max_amount,  :decimal

    timestamps()
  end

  @required [:block_id, :sys_id, :bank_id, :logo_id]
  @optional [
    :description,
    :apr_percentage, :cash_apr_percentage, :cash_advance_fee_percent,
    :annual_fee, :late_fee, :overlimit_fee,
    :overlimit_allowed, :min_payment_pct, :min_payment_floor,
    :min_payment_calculation, :grace_days, :payment_due_days,
    :cash_limit_pct, :statement_cycle_days,
    :credit_limit_default, :credit_limit_min, :credit_limit_max,
    :ecom_enabled, :atm_enabled, :intl_enabled, :contactless_enabled,
    :recurring_enabled, :moto_enabled,
    :stip_enabled, :stip_floor_limit, :stip_max_amount
  ]

  @min_pay_calcs ~w(PERCENTAGE_OF_BALANCE GREATER_OF_PCT_OR_FLOOR PERCENTAGE_PLUS_FEES FLAT_AMOUNT)

  def changeset(block, attrs) do
    block
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:block_id, is: 4)
    |> validate_length(:sys_id,   is: 4)
    |> validate_length(:bank_id,  is: 4)
    |> validate_length(:logo_id,  is: 4)
    |> maybe_validate_number(:apr_percentage,           greater_than_or_equal_to: 0)
    |> maybe_validate_number(:cash_apr_percentage,      greater_than_or_equal_to: 0)
    |> maybe_validate_number(:cash_advance_fee_percent, greater_than_or_equal_to: 0)
    |> maybe_validate_number(:annual_fee,               greater_than_or_equal_to: 0)
    |> maybe_validate_number(:late_fee,                 greater_than_or_equal_to: 0)
    |> maybe_validate_number(:overlimit_fee,            greater_than_or_equal_to: 0)
    |> maybe_validate_number(:min_payment_pct,          greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> maybe_validate_number(:cash_limit_pct,           greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> maybe_validate_number(:grace_days,               greater_than_or_equal_to: 0, less_than_or_equal_to: 60)
    |> maybe_validate_number(:credit_limit_default,     greater_than_or_equal_to: 0)
    |> maybe_validate_number(:credit_limit_min,         greater_than_or_equal_to: 0)
    |> maybe_validate_number(:credit_limit_max,         greater_than_or_equal_to: 0)
    |> maybe_validate_inclusion(:min_payment_calculation, @min_pay_calcs)
  end

  defp maybe_validate_number(cs, field, opts) do
    case get_field(cs, field) do
      nil -> cs
      _   -> validate_number(cs, field, opts)
    end
  end

  defp maybe_validate_inclusion(cs, field, valid) do
    case get_field(cs, field) do
      nil -> cs
      _   -> validate_inclusion(cs, field, valid)
    end
  end

  @doc "Returns a human-readable summary of which fields this block overrides."
  def overriding_fields(%__MODULE__{} = block) do
    [
      {block.apr_percentage,           "Purchase APR"},
      {block.cash_apr_percentage,      "Cash APR"},
      {block.cash_advance_fee_percent, "Cash Adv Fee"},
      {block.annual_fee,               "Annual Fee"},
      {block.late_fee,                 "Late Fee"},
      {block.overlimit_fee,            "Overlimit Fee"},
      {block.overlimit_allowed,        "Overlimit Allow"},
      {block.min_payment_pct,          "Min Payment %"},
      {block.grace_days,               "Grace Days"},
      {block.cash_limit_pct,           "Cash Limit %"},
      {block.credit_limit_default,     "Credit Limit"},
      {block.credit_limit_min,         "Limit Min"},
      {block.credit_limit_max,         "Limit Max"},
      {block.intl_enabled,             "Intl"},
      {block.ecom_enabled,             "eComm"},
      {block.atm_enabled,              "ATM"},
      {block.contactless_enabled,      "Contactless"},
      {block.stip_enabled,             "STIP"},
    ]
    |> Enum.reject(fn {val, _} -> is_nil(val) end)
    |> Enum.map(fn {_, label} -> label end)
  end
end
