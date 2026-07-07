defmodule VmuCore.Repo.Migrations.ExtendLogoParameters do
  @moduledoc """
  P1-A: Extend logo_parameters with product-level billing, fee, APR, and auth fields.

  These fields are required by the VisionPlus CMS specification for the LOGO control
  record to function as a complete product template. Previously only bin_prefix and
  description were stored; all pricing and behavioural parameters were missing.
  """

  use Ecto.Migration

  def change do
    alter table(:logo_parameters) do
      # ── Interest Rates ─────────────────────────────────────────────────────
      add :purchase_apr,       :decimal, precision: 7, scale: 4, null: false, default: 0
      add :cash_apr,           :decimal, precision: 7, scale: 4, null: false, default: 0
      add :penalty_apr,        :decimal, precision: 7, scale: 4, null: false, default: 0
      add :promo_apr,          :decimal, precision: 7, scale: 4, null: false, default: 0

      # ── Fees (all in base currency) ─────────────────────────────────────────
      add :annual_fee,         :decimal, precision: 18, scale: 2, null: false, default: 0
      add :late_fee,           :decimal, precision: 18, scale: 2, null: false, default: 0
      add :overlimit_fee,      :decimal, precision: 18, scale: 2, null: false, default: 0
      add :replacement_fee,    :decimal, precision: 18, scale: 2, null: false, default: 0
      add :returned_payment_fee, :decimal, precision: 18, scale: 2, null: false, default: 0

      # ── Billing Behaviour ───────────────────────────────────────────────────
      # min_payment_pct: minimum payment as percent of statement balance (e.g. 5.00)
      add :min_payment_pct,    :decimal, precision: 7, scale: 4, null: false, default: 5
      # min_payment_floor: absolute minimum payment floor in base currency
      add :min_payment_floor,  :decimal, precision: 18, scale: 2, null: false, default: 25
      # grace_days: number of days after statement to pay without retail interest
      add :grace_days,         :integer, null: false, default: 25
      # cash_limit_pct: cash advance sub-limit as % of credit_limit (e.g. 30.00)
      add :cash_limit_pct,     :decimal, precision: 7, scale: 4, null: false, default: 30
      # statement_cycle_days: typical cycle length for interest calculation fallback
      add :statement_cycle_days, :integer, null: false, default: 30

      # ── Authorisation Flags ─────────────────────────────────────────────────
      add :ecom_enabled,       :boolean, null: false, default: true
      add :atm_enabled,        :boolean, null: false, default: true
      add :intl_enabled,       :boolean, null: false, default: false
      add :contactless_enabled, :boolean, null: false, default: true

      # ── Credit Limit Defaults ───────────────────────────────────────────────
      add :credit_limit_default, :decimal, precision: 18, scale: 2
      add :credit_limit_max,     :decimal, precision: 18, scale: 2
    end

    create index(:logo_parameters, [:sys_id, :bank_id, :logo_id],
             name: :logo_parameters_hierarchy_idx, unique: true)
  end
end
