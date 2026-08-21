defmodule VmuCore.Repo.Migrations.CreateGlExtractions do
  @moduledoc """
  Extraction state for journal entries handed to an external consumer
  (GL Phase C3).

  ## Why a table and not a column

  `cms_ledger_entries` carried `extracted_at` on the row itself, and
  `CMS.CoreBankingAdapter` stamped it in place. Two reasons not to repeat that
  on `journal_entries`:

  1. **The subledger is immutable.** A journal entry records what was posted.
     Extraction is something that later happened *to* it, by a party outside
     the ledger, and writing that back mutates an accounting record to track a
     delivery concern.

  2. **There is more than one consumer.** A single `extracted_at` can only
     answer "was this sent", not "was this sent *to whom*". Core banking today;
     a regulator feed or a data warehouse tomorrow. Keying on
     `(journal_entry_id, destination)` costs nothing now and avoids a migration
     the first time a second consumer appears.
  """
  use Ecto.Migration

  def change do
    create table(:gl_extractions, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :journal_entry_id,
          references(:journal_entries, type: :binary_id, on_delete: :restrict),
          null: false

      # Who received it. Defaulted so the existing single-consumer caller does
      # not have to name itself, but stored explicitly so the answer to
      # "extracted?" is always qualified by "to where".
      add :destination, :string, size: 40, null: false, default: "CORE_BANKING"

      add :extracted_at, :utc_datetime_usec, null: false
      # Groups the entries sent in one submission, so a failed transmission can
      # be identified and re-driven as a unit.
      add :batch_ref, :string, size: 100

      timestamps(type: :utc_datetime_usec)
    end

    # The idempotency guarantee: one extraction per entry per destination. A
    # re-run of the same EOD extract conflicts here rather than double-sending.
    create unique_index(:gl_extractions, [:journal_entry_id, :destination],
             name: :gl_extractions_entry_destination_idx
           )

    # Drives "what has this destination not yet seen".
    create index(:gl_extractions, [:destination, :extracted_at])
    create index(:gl_extractions, [:batch_ref])
  end
end
