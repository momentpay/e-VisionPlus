defmodule VmuCore.Repo.Migrations.AddExtractedAtToLedgerEntries do
  @moduledoc """
  Sprint 3J: Add extracted_at to cms_ledger_entries for GL extract tracking.

  `extracted_at` is set by CoreBankingAdapter after a GL entry has been
  successfully transmitted to the core banking system. NULL means not yet
  extracted; the extract query filters on IS NULL for idempotency.
  """

  use Ecto.Migration

  def change do
    alter table(:cms_ledger_entries) do
      add :extracted_at, :naive_datetime
    end

    # Index for the un-extracted query pattern: WHERE extracted_at IS NULL AND posting_date = ?
    create index(:cms_ledger_entries, [:posting_date, :extracted_at],
      name: :cms_ledger_entries_extract_idx,
      where: "extracted_at IS NULL"
    )
  end
end
