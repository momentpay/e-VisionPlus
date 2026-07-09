defmodule VmuCore.Shared.BankParameter do
  @moduledoc """
  VisionPlus BANK / ORGANISATION control record.

  The BANK record sits below SYS and above LOGO in the parameter hierarchy:

      SYS  →  BANK  →  LOGO  →  BLOCK

  Each bank can define institution-wide overrides for tax treatment, GL mapping,
  delinquency rules, and settlement scheduling.

  ## Key Fields

  - `country_code`       — ISO 3166-1 alpha-3 (e.g. "ARE" for UAE)
  - `tax_rule`           — VAT rate, tax code, exempt MCC categories
  - `gl_mapping_profile` — identifier linking to the bank's chart-of-accounts
  - `delinquency_rules`  — DPD-to-COL thresholds, write-off days
  - `settlement_calendar`— non-working days, settlement cutoff
  - `swift_bic`          — SWIFT BIC for outgoing settlement messages

  ## tax_rule Example

      %{
        "vat_rate"        => "0.05",
        "tax_code"        => "AE-VAT",
        "exempt_mcc_list" => ["5411", "5912"],
        "tax_on_fees"     => true,
        "tax_on_interest" => false
      }

  ## delinquency_rules Example

      %{
        "col_handoff_dpd"  => 120,
        "write_off_dpd"    => 180,
        "suspend_at_dpd"   => 60,
        "penalty_apr_dpd"  => 30
      }

  ## settlement_calendar Example

      %{
        "cutoff_time"     => "23:00",
        "non_working_days"=> ["2026-01-01", "2026-12-25"],
        "settlement_days" => ["MON","TUE","WED","THU"]
      }
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "bank_parameters" do
    field :bank_id,            :string, primary_key: true
    field :sys_id,             :string, primary_key: true
    field :description,        :string
    field :country_code,       :string, default: "ARE"

    # Extended control fields
    field :tax_rule,            :map
    field :gl_mapping_profile,  :string
    field :delinquency_rules,   :map
    field :settlement_calendar, :map
    field :swift_bic,           :string

    # Multi-org isolation fields (4C)
    field :base_currency,       :string, default: "AED"
    field :billing_timezone,    :string, default: "Asia/Dubai"
    field :regulatory_regime,   :string, default: "CBUAE"
    field :org_name,            :string
    field :org_type,            :string, default: "BANK"
    # Bank-size org tier (ASM role taxonomy, docs/asm/ASM_Role_Taxonomy.md) — nullable,
    # advisory only. Drives the recommended-roles hint in the operator-creation
    # screen; does not restrict which roles can actually be assigned.
    field :org_size,            :string

    # Market-level payment + bureau config (CMS-G1 ADR-C1/C3/C5)
    field :payment_channels_enabled, :string, default: "gateway,direct_debit"
    field :credit_reporting_format,  :string, default: "Metro2"

    timestamps()
  end

  @org_types ~w(BANK FINANCIAL_INSTITUTION CREDIT_UNION MICROFINANCE NEOBANK EMI PSP OTHER)
  @org_sizes ~w(SMALL MEDIUM LARGE)

  @required [:bank_id, :sys_id, :description]
  @optional [:country_code, :tax_rule, :gl_mapping_profile,
             :delinquency_rules, :settlement_calendar, :swift_bic,
             :base_currency, :billing_timezone, :regulatory_regime, :org_name, :org_type,
             :org_size, :payment_channels_enabled, :credit_reporting_format]

  def changeset(bank_parameter, attrs) do
    bank_parameter
    |> cast(attrs, @required ++ @optional)
    |> update_change(:org_size, fn "" -> nil; v -> v end)
    |> validate_required(@required)
    |> validate_length(:bank_id,            is: 4)
    |> validate_length(:sys_id,             is: 4)
    |> validate_length(:country_code,       is: 3)
    |> validate_length(:swift_bic,          max: 11)
    |> validate_length(:gl_mapping_profile, max: 20)
    |> validate_length(:base_currency,      is: 3)
    |> validate_length(:regulatory_regime,  max: 20)
    |> validate_inclusion(:org_type, @org_types)
    |> validate_inclusion(:org_size, @org_sizes)
  end

  def org_size_options do
    [
      {"-- Not specified --", ""},
      {"Small (community bank / small credit union / neobank)", "SMALL"},
      {"Medium (regional bank / credit union)", "MEDIUM"},
      {"Large (national/regional bank, specialist teams)", "LARGE"}
    ]
  end

  def org_type_options do
    [
      {"Bank (licensed commercial bank)", "BANK"},
      {"Financial Institution (non-bank)", "FINANCIAL_INSTITUTION"},
      {"Credit Union / Cooperative", "CREDIT_UNION"},
      {"Microfinance Institution (MFI)", "MICROFINANCE"},
      {"Neobank / Digital Bank", "NEOBANK"},
      {"Electronic Money Institution (EMI)", "EMI"},
      {"Payment Service Provider (PSP)", "PSP"},
      {"Other", "OTHER"}
    ]
  end

  # ── Convenience accessors ───────────────────────────────────────────────────

  @doc "VAT rate as Decimal, e.g. Decimal.new(\"0.05\"). Nil if not configured."
  def vat_rate(%__MODULE__{tax_rule: nil}), do: nil
  def vat_rate(%__MODULE__{tax_rule: tr}) do
    case Map.get(tr, "vat_rate") do
      nil  -> nil
      rate -> Decimal.new(to_string(rate))
    end
  end

  @doc "DPD threshold at which the account should be handed off to COL. Defaults to 120."
  def col_handoff_dpd(%__MODULE__{delinquency_rules: nil}), do: 120
  def col_handoff_dpd(%__MODULE__{delinquency_rules: dr}) do
    Map.get(dr, "col_handoff_dpd") || 120
  end

  @doc "DPD threshold for penalty APR escalation. Defaults to 30."
  def penalty_apr_dpd(%__MODULE__{delinquency_rules: nil}), do: 30
  def penalty_apr_dpd(%__MODULE__{delinquency_rules: dr}) do
    Map.get(dr, "penalty_apr_dpd") || 30
  end
end
