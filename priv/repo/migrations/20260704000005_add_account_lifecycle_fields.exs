defmodule VmuCore.Repo.Migrations.AddAccountLifecycleFields do
  use Ecto.Migration

  # CMS-G3: account lifecycle state.
  # - closure_requested_at: closure pending until balance zeroes (FR-CMS-007)
  # - dormant_since: inactivity flag set/cleared by the lifecycle sweep (FR-CMS-015)
  def change do
    alter table(:cms_accounts) do
      add :closure_requested_at, :utc_datetime
      add :dormant_since,        :date
    end

    create index(:cms_accounts, [:closure_requested_at],
             where: "closure_requested_at IS NOT NULL")
    create index(:cms_accounts, [:dormant_since],
             where: "dormant_since IS NOT NULL")
  end
end
