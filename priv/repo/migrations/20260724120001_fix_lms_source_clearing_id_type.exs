defmodule VmuCore.Repo.Migrations.FixLmsSourceClearingIdType do
  use Ecto.Migration

  def change do
    # Found while building LMS-P1's clawback feature (FR-LMS-012, 2026-07-24):
    # lms_points_ledger.source_clearing_id was created :bigint in the
    # original 2026-06-14 LMS migration, before trams_clearing_records'
    # real uuid PK (clearing_id) was finalized (2026-07-03). Never
    # reconciled afterward — PointsEngine.post_earned_points/7 has always
    # passed a real ClearingRecord.clearing_id (uuid) into this column,
    # which would fail every real Ecto cast. 0 rows have this column
    # populated in dev, confirming the real earn pipeline
    # (PointsCalculationJob -> PointsEngine) has never actually succeeded
    # against real clearing data. Safe type change, nothing to migrate.
    alter table(:lms_points_ledger) do
      remove :source_clearing_id, :bigint
      add :source_clearing_id, :uuid
    end
  end
end
