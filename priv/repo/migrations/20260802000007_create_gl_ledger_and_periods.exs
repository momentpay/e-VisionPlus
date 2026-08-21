defmodule VmuCore.Repo.Migrations.CreateGlLedgerAndPeriods do
  @moduledoc """
  GL Phase A4 — the consolidated ledger, banking dates, accounting periods,
  and the closed-period exception control (Koṣa DOC-110; WAY4 `GL_TRANSFER`,
  banking date, GL entry closing, GL Trace Exceptions).

  ## Why banking date is its own table

  It is per-institution (WAY4 is, and EOD already runs per BANK) but it is
  **operational state that changes daily**, not configuration. Putting it in
  `bank_parameters` alongside APRs and country codes would mix a value that
  moves every night into a table whose whole point is that it does not.

  ## Consolidation

  A GL ledger entry is one row per
  `(sys_id, bank_id, gl_date, dr_account, cr_account, currency, generation)`.
  Journal entries accumulate into it; it is the bank's-books view, where
  journal entries are the customer's-account view.

  `generation` implements WAY4's rule that once an entry is closed, further
  activity for the same account correspondence on the same date opens a
  *second* entry rather than reopening the first. Without it, closing would
  either be a lie or would have to reject late activity outright.

  ## The exception control

  WAY4's "GL Trace Exceptions" — postings whose `gl_date` falls in an already
  closed period. WAY4's rule is that this table is empty in a healthy system;
  a non-empty one means processes ran out of order. Quarantining beats both
  silently accepting the posting into a closed period and losing it.
  """
  use Ecto.Migration

  def change do
    # -- Banking date, per institution ----------------------------------------
    create table(:gl_banking_dates, primary_key: false) do
      add :sys_id,  :string, size: 4, primary_key: true
      add :bank_id, :string, size: 4, primary_key: true

      add :current_banking_date, :date, null: false
      add :status,               :string, size: 10, null: false, default: "OPEN"
      add :last_closed_date,     :date
      add :opened_at,            :utc_datetime_usec
      add :closed_at,            :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create constraint(:gl_banking_dates, :gl_banking_dates_status_check,
             check: "status IN ('OPEN','CLOSING','CLOSED')")

    # -- Accounting periods ----------------------------------------------------
    create table(:gl_periods) do
      add :sys_id,  :string, size: 4, null: false
      add :bank_id, :string, size: 4, null: false

      add :period_start, :date, null: false
      add :period_end,   :date, null: false
      add :status,       :string, size: 10, null: false, default: "OPEN"

      add :closed_at, :utc_datetime_usec
      add :closed_by, :string
      add :locked_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gl_periods, [:sys_id, :bank_id, :period_start])
    create index(:gl_periods, [:sys_id, :bank_id, :status])

    create constraint(:gl_periods, :gl_periods_status_check,
             check: "status IN ('OPEN','CLOSED','LOCKED')")
    create constraint(:gl_periods, :gl_periods_range_check,
             check: "period_end >= period_start")

    # Periods for one institution may not overlap. A daterange exclusion
    # constraint enforces it in the database — application-level checking
    # races under concurrent period creation.
    execute "CREATE EXTENSION IF NOT EXISTS btree_gist",
            "DROP EXTENSION IF EXISTS btree_gist"

    execute """
            ALTER TABLE gl_periods ADD CONSTRAINT gl_periods_no_overlap
            EXCLUDE USING gist (
              sys_id WITH =,
              bank_id WITH =,
              daterange(period_start, period_end, '[]') WITH &&
            )
            """,
            "ALTER TABLE gl_periods DROP CONSTRAINT gl_periods_no_overlap"

    # -- Consolidated GL ledger entries ---------------------------------------
    create table(:gl_ledger_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :sys_id,  :string, size: 4, null: false
      add :bank_id, :string, size: 4, null: false

      add :gl_date, :date, null: false
      add :dr_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false
      add :cr_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false
      add :currency,   :string, size: 3, null: false

      add :amount,      :decimal, precision: 20, scale: 4, null: false, default: 0
      add :entry_count, :integer, null: false, default: 0
      add :generation,  :integer, null: false, default: 1

      # WAY4's lifecycle: OPEN (accumulating) → EXTRACTED (manually closed for
      # reporting) → CLOSED (exported, turnover applied).
      add :status,       :string, size: 10, null: false, default: "OPEN"
      add :extracted_at, :utc_datetime_usec
      add :closed_at,    :utc_datetime_usec

      add :period_id, references(:gl_periods, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:gl_ledger_entries,
             [:sys_id, :bank_id, :gl_date, :dr_account, :cr_account, :currency, :generation],
             name: :gl_ledger_entries_correspondence_idx)

    create index(:gl_ledger_entries, [:gl_date, :status])
    create index(:gl_ledger_entries, [:dr_account])
    create index(:gl_ledger_entries, [:cr_account])

    create constraint(:gl_ledger_entries, :gl_ledger_entries_status_check,
             check: "status IN ('OPEN','EXTRACTED','CLOSED')")
    create constraint(:gl_ledger_entries, :gl_ledger_entries_distinct_accounts_check,
             check: "dr_account <> cr_account")
    create constraint(:gl_ledger_entries, :gl_ledger_entries_amount_non_negative_check,
             check: "amount >= 0")

    # -- Closed-period exception quarantine -----------------------------------
    create table(:gl_posting_exceptions) do
      add :sys_id,  :string, size: 4, null: false
      add :bank_id, :string, size: 4, null: false

      add :posting_set_id, references(:posting_sets, type: :binary_id, on_delete: :restrict)

      add :attempted_gl_date, :date, null: false
      add :banking_date,      :date, null: false
      add :close_point,       :date

      add :reason,     :string, size: 40, null: false
      add :detail,     :text
      add :resolved,   :boolean, null: false, default: false
      add :resolved_at, :utc_datetime_usec
      add :resolved_by, :string
      add :resolution,  :text

      timestamps(type: :utc_datetime_usec)
    end

    create index(:gl_posting_exceptions, [:resolved], where: "resolved = false",
                 name: :gl_posting_exceptions_open_idx)
    create index(:gl_posting_exceptions, [:sys_id, :bank_id, :attempted_gl_date])

    create constraint(:gl_posting_exceptions, :gl_posting_exceptions_reason_check,
             check: "reason IN ('GL_DATE_IN_CLOSED_PERIOD','GL_DATE_BEFORE_CLOSE_POINT'," <>
                    "'NO_OPEN_PERIOD','BANKING_DATE_CLOSED')")
  end
end
