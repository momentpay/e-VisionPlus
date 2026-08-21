defmodule VmuCore.Repo.Migrations.CreateWpsSalaryCreditExceptions do
  @moduledoc """
  The disbursement exception queue (Phase W3).

  ## Why failures get their own table rather than a status

  `wps_salary_credits.status` already records *that* a line failed. What it
  cannot record is the operational history: what was tried, when, by whom, what
  the system said, and whether anyone has looked at it. A WPS batch is a
  regulated payment instruction — a worker who was not paid is a compliance
  event, not a log line — and "failed silently and nobody noticed" is the
  outcome this table exists to prevent.

  Requirements §4 puts it plainly: failed disbursements "need a real remediation
  workflow, not silent drops".

  ## One open exception per credit

  A partial unique index enforces it. Retrying a line resolves the existing
  exception rather than stacking a second one, so an operator's queue shows work
  outstanding rather than an audit trail of every attempt — the attempts live in
  `attempt_count` and `last_attempted_at`.
  """
  use Ecto.Migration

  def change do
    create table(:wps_salary_credit_exceptions, primary_key: false) do
      add :exception_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :salary_credit_id,
          references(:wps_salary_credits,
            column: :salary_credit_id,
            type: :binary_id,
            on_delete: :delete_all
          ),
          null: false

      add :employer_id,
          references(:wps_employers, column: :employer_id, type: :binary_id, on_delete: :restrict),
          null: false

      # Classification drives the queue: an operator fixes all the
      # BENEFICIARY_UNRESOLVED lines one way and all the ACCOUNT_INACTIVE lines
      # another, so grouping by cause is what makes the queue workable at the
      # scale a payroll batch produces.
      #
      # BENEFICIARY_UNRESOLVED — no roster link for this employee
      # BENEFICIARY_NOT_ACTIVE — link exists but is unverified or suspended
      # ACCOUNT_INACTIVE       — the prepaid account is closed or blocked
      # POSTING_FAILED         — the ledger or GL refused the posting
      # VALIDATION_FAILED      — the line itself is not payable
      add :exception_type, :string, size: 40, null: false
      add :reason, :string, size: 500, null: false

      # OPEN — needs an operator
      # RESOLVED — retried successfully, or closed by hand
      # ABANDONED — deliberately not going to be paid
      add :status, :string, size: 20, null: false, default: "OPEN"

      add :attempt_count, :integer, null: false, default: 1
      add :last_attempted_at, :utc_datetime_usec

      add :resolved_at, :utc_datetime_usec
      add :resolved_by, :string, size: 100
      add :resolution_note, :string, size: 500

      timestamps(type: :utc_datetime_usec)
    end

    # At most one OPEN exception per credit. Retries update it in place; the
    # queue shows outstanding work, not a history of every attempt.
    create unique_index(:wps_salary_credit_exceptions, [:salary_credit_id],
             where: "status = 'OPEN'",
             name: :wps_salary_credit_exceptions_one_open_idx
           )

    create index(:wps_salary_credit_exceptions, [:employer_id, :status])
    create index(:wps_salary_credit_exceptions, [:exception_type, :status])

    create constraint(:wps_salary_credit_exceptions, :wps_salary_credit_exceptions_status_check,
             check: "status IN ('OPEN','RESOLVED','ABANDONED')"
           )

    create constraint(:wps_salary_credit_exceptions, :wps_salary_credit_exceptions_type_check,
             check:
               "exception_type IN ('BENEFICIARY_UNRESOLVED','BENEFICIARY_NOT_ACTIVE'," <>
                 "'ACCOUNT_INACTIVE','POSTING_FAILED','VALIDATION_FAILED')"
           )
  end
end
