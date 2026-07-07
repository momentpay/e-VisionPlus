defmodule VmuCore.Shared.LogoParameter do
  @moduledoc """
  VisionPlus LOGO control record — the card product template layer.

  Hierarchy: SYS → ORGANIZATION → LOGO → BLOCK

  A LOGO defines the complete product configuration for a card programme:
  identity (BIN, scheme, product type), interest rates, fees, billing behaviour,
  authorisation channel flags, credit limits, and STIP stand-in processing.
  BLOCK-level records can override individual fields for specific sub-products.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @card_schemes   ~w(VISA MASTERCARD AMEX UNIONPAY DISCOVER DINERS LOCAL_NETWORK OTHER)
  @product_types  ~w(CREDIT DEBIT PREPAID CORPORATE GOVERNMENT FLEET)
  @calc_methods   ~w(AVERAGE_DAILY_BALANCE ADJUSTED_BALANCE PREVIOUS_BALANCE DAILY_BALANCE)
  @min_pay_calcs  ~w(PERCENTAGE_OF_BALANCE GREATER_OF_PCT_OR_FLOOR PERCENTAGE_PLUS_FEES FLAT_AMOUNT)
  @fee_postings   ~w(UPON_ACTIVATION CYCLE_1 ANNIVERSARY MONTHLY QUARTERLY)

  @primary_key false
  schema "logo_parameters" do
    field :logo_id,    :string, primary_key: true
    field :sys_id,     :string, primary_key: true
    field :bank_id,    :string, primary_key: true

    # ── Identity ──────────────────────────────────────────────────────────────
    field :bin_prefix,   :string
    field :description,  :string
    field :card_scheme,  :string
    field :product_type, :string

    # ── Interest Rates ────────────────────────────────────────────────────────
    field :purchase_apr,                :decimal, default: Decimal.new(0)
    field :cash_apr,                    :decimal, default: Decimal.new(0)
    field :penalty_apr,                 :decimal, default: Decimal.new(0)
    field :penalty_apr_dpd_trigger,     :integer, default: 60
    field :promo_apr,                   :decimal, default: Decimal.new(0)
    field :interest_calculation_method, :string,  default: "AVERAGE_DAILY_BALANCE"

    # ── Fees ──────────────────────────────────────────────────────────────────
    field :annual_fee,                      :decimal, default: Decimal.new(0)
    field :annual_fee_posting,              :string,  default: "UPON_ACTIVATION"
    field :late_fee,                        :decimal, default: Decimal.new(0)
    field :overlimit_fee,                   :decimal, default: Decimal.new(0)
    field :replacement_fee,                 :decimal, default: Decimal.new(0)
    field :returned_payment_fee,            :decimal, default: Decimal.new(0)
    field :card_replacement_fee,            :decimal, default: Decimal.new(0)
    field :cash_advance_fee_percent,        :decimal, default: Decimal.new(0)
    field :cash_advance_fee_min,            :decimal, default: Decimal.new(0)
    field :foreign_transaction_fee_percent, :decimal, default: Decimal.new(0)

    # ── Billing Behaviour ─────────────────────────────────────────────────────
    field :min_payment_pct,         :decimal, default: Decimal.new("5.0")
    field :min_payment_floor,       :decimal, default: Decimal.new("25.0")
    field :min_payment_calculation, :string,  default: "PERCENTAGE_OF_BALANCE"
    field :grace_days,              :integer, default: 25
    field :payment_due_days,        :integer, default: 25
    field :cash_limit_pct,          :decimal, default: Decimal.new("30.0")
    field :statement_cycle_days,    :integer, default: 30

    # ── Overlimit ─────────────────────────────────────────────────────────────
    field :overlimit_allowed,       :boolean, default: false
    field :overlimit_tolerance_pct, :decimal, default: Decimal.new(0)

    # ── Authorisation Channel Flags ───────────────────────────────────────────
    field :ecom_enabled,        :boolean, default: true
    field :atm_enabled,         :boolean, default: true
    field :intl_enabled,        :boolean, default: false
    field :contactless_enabled, :boolean, default: true
    field :recurring_enabled,   :boolean, default: true
    field :moto_enabled,        :boolean, default: false
    field :quasi_cash_enabled,  :boolean, default: false
    field :cash_back_enabled,   :boolean, default: false

    # ── Transaction Limits ────────────────────────────────────────────────────
    field :single_txn_max,      :decimal   # max amount per single txn (nil = uncapped)
    field :daily_txn_max_count, :integer   # max txn count per day (nil = uncapped)
    field :daily_txn_max_amount, :decimal  # max total debit amount per day (nil = uncapped)

    # ── Card / Chip / PIN ─────────────────────────────────────────────────────
    field :chip_enabled,                :boolean, default: true
    field :mag_stripe_enabled,          :boolean, default: true
    field :pin_required,                :boolean, default: true
    field :card_validity_years,         :integer, default: 3
    field :supplementary_cards_allowed, :boolean, default: true
    field :supplementary_card_limit,    :integer, default: 3

    # ── Credit Limit Bounds ───────────────────────────────────────────────────
    field :credit_limit_min,     :decimal
    field :credit_limit_default, :decimal
    field :credit_limit_max,     :decimal

    # ── STIP (Stand-In Processing) ────────────────────────────────────────────
    field :stip_enabled,     :boolean, default: false
    field :stip_floor_limit, :decimal, default: Decimal.new("50.0")
    field :stip_max_amount,  :decimal, default: Decimal.new("500.0")

    # ── Payment allocation + penalty cure (CMS-G1 ADR-C1/C2) ─────────────────
    # CSV bucket order, highest priority first; nil → scheme default
    field :repayment_hierarchy_order, :string
    # "arrears_cleared_immediately" | "arrears_cleared_and_<N>_cycles_current"
    field :penalty_apr_cure_rule, :string, default: "arrears_cleared_immediately"

    timestamps()
  end

  @required [:logo_id, :sys_id, :bank_id, :bin_prefix, :description]
  @optional [
    :card_scheme, :product_type,
    :purchase_apr, :cash_apr, :penalty_apr, :penalty_apr_dpd_trigger, :promo_apr,
    :interest_calculation_method,
    :annual_fee, :annual_fee_posting, :late_fee, :overlimit_fee,
    :replacement_fee, :returned_payment_fee, :card_replacement_fee,
    :cash_advance_fee_percent, :cash_advance_fee_min, :foreign_transaction_fee_percent,
    :min_payment_pct, :min_payment_floor, :min_payment_calculation,
    :grace_days, :payment_due_days, :cash_limit_pct, :statement_cycle_days,
    :overlimit_allowed, :overlimit_tolerance_pct,
    :ecom_enabled, :atm_enabled, :intl_enabled, :contactless_enabled,
    :recurring_enabled, :moto_enabled, :quasi_cash_enabled, :cash_back_enabled,
    :single_txn_max, :daily_txn_max_count, :daily_txn_max_amount,
    :chip_enabled, :mag_stripe_enabled, :pin_required,
    :card_validity_years, :supplementary_cards_allowed, :supplementary_card_limit,
    :credit_limit_min, :credit_limit_default, :credit_limit_max,
    :stip_enabled, :stip_floor_limit, :stip_max_amount,
    :repayment_hierarchy_order, :penalty_apr_cure_rule
  ]

  def changeset(logo, attrs) do
    logo
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:logo_id,    is: 4)
    |> validate_length(:sys_id,     is: 4)
    |> validate_length(:bank_id,    is: 4)
    |> validate_length(:bin_prefix, is: 6)
    |> maybe_validate_inclusion(:card_scheme,  @card_schemes)
    |> maybe_validate_inclusion(:product_type, @product_types)
    |> maybe_validate_inclusion(:interest_calculation_method, @calc_methods)
    |> maybe_validate_inclusion(:min_payment_calculation,     @min_pay_calcs)
    |> maybe_validate_inclusion(:annual_fee_posting,          @fee_postings)
    |> validate_number(:purchase_apr,    greater_than_or_equal_to: 0)
    |> validate_number(:cash_apr,        greater_than_or_equal_to: 0)
    |> validate_number(:penalty_apr,     greater_than_or_equal_to: 0)
    |> validate_number(:promo_apr,       greater_than_or_equal_to: 0)
    |> validate_number(:annual_fee,      greater_than_or_equal_to: 0)
    |> validate_number(:late_fee,        greater_than_or_equal_to: 0)
    |> validate_number(:overlimit_fee,   greater_than_or_equal_to: 0)
    |> validate_number(:min_payment_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:cash_limit_pct,  greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:grace_days,      greater_than_or_equal_to: 0, less_than_or_equal_to: 60)
    |> validate_number(:card_validity_years,      greater_than_or_equal_to: 1, less_than_or_equal_to: 10)
    |> validate_number(:supplementary_card_limit, greater_than_or_equal_to: 0)
  end

  defp maybe_validate_inclusion(cs, field, valid) do
    case get_field(cs, field) do
      nil -> cs
      _   -> validate_inclusion(cs, field, valid)
    end
  end

  # ── Option lists for UI select dropdowns ───────────────────────────────────

  def card_scheme_options do
    [
      {"-- Select --", ""},
      {"Visa", "VISA"},
      {"Mastercard", "MASTERCARD"},
      {"American Express", "AMEX"},
      {"UnionPay", "UNIONPAY"},
      {"Discover", "DISCOVER"},
      {"Diners Club", "DINERS"},
      {"Local / Proprietary Network", "LOCAL_NETWORK"},
      {"Other", "OTHER"}
    ]
  end

  def product_type_options do
    [
      {"-- Select --", ""},
      {"Credit Card", "CREDIT"},
      {"Debit Card", "DEBIT"},
      {"Prepaid / Stored Value", "PREPAID"},
      {"Corporate Card", "CORPORATE"},
      {"Government Card", "GOVERNMENT"},
      {"Fleet / Fuel Card", "FLEET"}
    ]
  end

  def calc_method_options do
    [
      {"Average Daily Balance (ADB) — most common", "AVERAGE_DAILY_BALANCE"},
      {"Adjusted Balance (after payments applied)", "ADJUSTED_BALANCE"},
      {"Previous Statement Balance", "PREVIOUS_BALANCE"},
      {"Daily Compounding Balance", "DAILY_BALANCE"}
    ]
  end

  def min_pay_options do
    [
      {"% of Statement Balance", "PERCENTAGE_OF_BALANCE"},
      {"Greater of % or Floor Amount", "GREATER_OF_PCT_OR_FLOOR"},
      {"% of Balance + All Fees and Charges", "PERCENTAGE_PLUS_FEES"},
      {"Flat Fixed Amount", "FLAT_AMOUNT"}
    ]
  end

  def fee_posting_options do
    [
      {"Upon Card Activation", "UPON_ACTIVATION"},
      {"First Billing Cycle", "CYCLE_1"},
      {"Account Anniversary Date", "ANNIVERSARY"},
      {"Monthly (recurring)", "MONTHLY"},
      {"Quarterly (recurring)", "QUARTERLY"}
    ]
  end

  def card_validity_options do
    Enum.map(1..10, &{"#{&1} year#{if &1 > 1, do: "s"}", to_string(&1)})
  end

  def supplementary_limit_options do
    Enum.map(0..10, &{to_string(&1), to_string(&1)})
  end
end
