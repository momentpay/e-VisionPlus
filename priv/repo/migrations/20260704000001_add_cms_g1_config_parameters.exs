defmodule VmuCore.Repo.Migrations.AddCmsG1ConfigParameters do
  use Ecto.Migration

  # CMS-G1 (docs/cms/CMS_Gap_Implementation_Tracker.md, ADR-C1/C2):
  # the four reviewed Open-Question parameters land in the SYS→BANK→LOGO→BLOCK
  # cascade, plus account-level penalty-APR persistence state.
  def change do
    alter table(:logo_parameters) do
      # CSV of bucket names, highest priority first; nil → scheme default
      # (unpaid_fees,accrued_interest,emi_balance,cash_balance,bt_balance,retail_balance)
      add :repayment_hierarchy_order, :string, size: 200
      # "arrears_cleared_immediately" | "arrears_cleared_and_<N>_cycles_current"
      add :penalty_apr_cure_rule, :string, size: 60,
          default: "arrears_cleared_immediately"
    end

    alter table(:bank_parameters) do
      # v1 scope per reviewed answer: gateway + direct_debit
      add :payment_channels_enabled, :string, size: 120,
          default: "gateway,direct_debit"
      # "Metro2" | "CIBIL_local" | "AlEtihad_local" (per-market)
      add :credit_reporting_format, :string, size: 30, default: "Metro2"
    end

    alter table(:cms_accounts) do
      # Penalty APR persists once triggered, until the cure rule is satisfied
      # (ADR-C2) — previously it silently dropped when DPD fell below trigger
      add :penalty_apr_active, :boolean, null: false, default: false
      # Consecutive current cycles since arrears cleared (for N-cycles cure)
      add :penalty_cure_cycles, :smallint, null: false, default: 0
    end
  end
end
