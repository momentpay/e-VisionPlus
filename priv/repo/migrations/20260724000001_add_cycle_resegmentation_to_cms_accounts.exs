defmodule VmuCore.Repo.Migrations.AddCycleResegmentationToCmsAccounts do
  use Ecto.Migration

  def change do
    alter table(:cms_accounts) do
      # Pending cycle_code change (FR-058) — never applied instantly; takes
      # effect on cycle_change_effective_date (respects the bank's
      # configured resegmentation_notice_days) via a real daily EOD job,
      # not a synchronous write.
      add :pending_cycle_code,          :integer
      add :cycle_change_effective_date, :date
      # Proration policy captured at schedule time (not read fresh at apply
      # time) so a later config change can't silently alter an
      # already-communicated commitment to the cardholder.
      add :cycle_change_proration_method, :string, size: 20
      # Last real cycle_code change (schedule-time, not apply-time) — the
      # anchor for resegmentation_min_interval_months. Distinct from
      # updated_at, which changes for unrelated reasons.
      add :cycle_code_changed_at, :naive_datetime
    end

    create index(:cms_accounts, [:cycle_change_effective_date],
      where: "pending_cycle_code IS NOT NULL")
  end
end
