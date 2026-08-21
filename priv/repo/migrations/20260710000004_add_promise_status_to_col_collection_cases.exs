defmodule VmuCore.Repo.Migrations.AddPromiseStatusToColCollectionCases do
  use Ecto.Migration

  def change do
    # COL-P7 — FR-COL-006b promise auto-verification. NULL when no promise has
    # ever been logged for the case; PENDING/KEPT/BROKEN once one has.
    alter table(:col_collection_cases) do
      add :promise_status, :string, size: 20
      # PENDING | KEPT | BROKEN
      add :promise_logged_at, :utc_datetime
      # When the promise was made — the baseline for "payments received since
      # the promise" so verification isn't confused by payments that predate it.
    end
  end
end
