defmodule VmuCore.Repo.Migrations.ExtendBlockParameters do
  @moduledoc """
  Phase 2 — extend block_parameters to support full sub-product overrides.

  Changes:
  1. Make the three existing NOT NULL columns nullable so nil = "inherit from LOGO".
  2. Add description (block tier name, e.g. "Gold Tier").
  3. Add full set of nullable override fields mirroring logo_parameters.
     Every field is nullable; a NULL value means the block inherits that value
     from its parent LOGO record via the ParameterEngine cascade.
  """
  use Ecto.Migration

  def up do
    # ── Make existing forced columns optional (nil = inherit from LOGO) ────────
    execute "ALTER TABLE block_parameters ALTER COLUMN apr_percentage DROP NOT NULL, ALTER COLUMN apr_percentage SET DEFAULT NULL"
    execute "ALTER TABLE block_parameters ALTER COLUMN cash_advance_fee_percent DROP NOT NULL, ALTER COLUMN cash_advance_fee_percent SET DEFAULT NULL"
    execute "ALTER TABLE block_parameters ALTER COLUMN credit_limit_default DROP NOT NULL, ALTER COLUMN credit_limit_default SET DEFAULT NULL"

    alter table(:block_parameters) do
      # Identity
      add :description, :string

      # Fee overrides
      add :annual_fee,              :decimal, precision: 15, scale: 2
      add :late_fee,                :decimal, precision: 15, scale: 2
      add :overlimit_fee,           :decimal, precision: 15, scale: 2

      # Billing overrides
      add :overlimit_allowed,       :boolean
      add :min_payment_pct,         :decimal, precision: 8, scale: 4
      add :min_payment_floor,       :decimal, precision: 15, scale: 2
      add :min_payment_calculation, :string
      add :grace_days,              :integer
      add :payment_due_days,        :integer
      add :cash_limit_pct,          :decimal, precision: 8, scale: 4
      add :statement_cycle_days,    :integer

      # Credit limit overrides
      add :credit_limit_min,        :decimal, precision: 15, scale: 2
      add :credit_limit_max,        :decimal, precision: 15, scale: 2

      # Auth channel overrides
      add :ecom_enabled,            :boolean
      add :atm_enabled,             :boolean
      add :intl_enabled,            :boolean
      add :contactless_enabled,     :boolean
      add :recurring_enabled,       :boolean
      add :moto_enabled,            :boolean

      # STIP overrides
      add :stip_enabled,            :boolean
      add :stip_floor_limit,        :decimal, precision: 15, scale: 2
      add :stip_max_amount,         :decimal, precision: 15, scale: 2
    end
  end

  def down do
    alter table(:block_parameters) do
      remove :description
      remove :annual_fee
      remove :late_fee
      remove :overlimit_fee
      remove :overlimit_allowed
      remove :min_payment_pct
      remove :min_payment_floor
      remove :min_payment_calculation
      remove :grace_days
      remove :payment_due_days
      remove :cash_limit_pct
      remove :statement_cycle_days
      remove :credit_limit_min
      remove :credit_limit_max
      remove :ecom_enabled
      remove :atm_enabled
      remove :intl_enabled
      remove :contactless_enabled
      remove :recurring_enabled
      remove :moto_enabled
      remove :stip_enabled
      remove :stip_floor_limit
      remove :stip_max_amount
    end

    execute "ALTER TABLE block_parameters ALTER COLUMN apr_percentage SET NOT NULL, ALTER COLUMN apr_percentage SET DEFAULT 24.0"
    execute "ALTER TABLE block_parameters ALTER COLUMN cash_advance_fee_percent SET NOT NULL, ALTER COLUMN cash_advance_fee_percent SET DEFAULT 3.0"
    execute "ALTER TABLE block_parameters ALTER COLUMN credit_limit_default SET NOT NULL, ALTER COLUMN credit_limit_default SET DEFAULT 5000.0"
  end
end
