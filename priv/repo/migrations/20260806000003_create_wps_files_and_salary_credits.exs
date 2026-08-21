defmodule VmuCore.Repo.Migrations.CreateWpsFilesAndSalaryCredits do
  @moduledoc """
  Salary file ingestion (Phase W2).

  ## Two tables, because a file and its lines fail independently

  A file can parse completely and still contain lines that cannot be paid, and a
  line can be perfectly valid in a file that must be rejected as a duplicate.
  Keeping the file's own lifecycle separate from each line's is what makes
  "17 of 400 lines failed, the rest paid" expressible — which is the normal
  outcome for a WPS batch, not an exception.

  ## `content_hash`

  The guard against paying a batch twice. A salary file re-sent after a failed
  transmission is byte-identical, and an employer re-submitting a corrected file
  is not — so hashing the bytes distinguishes the two cases without asking the
  employer to get a sequence number right.
  """
  use Ecto.Migration

  def change do
    create table(:wps_files, primary_key: false) do
      add :wps_file_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :employer_id,
          references(:wps_employers, column: :employer_id, type: :binary_id, on_delete: :restrict),
          null: false

      add :filename, :string, size: 300, null: false
      # SHA-256 of the raw bytes.
      add :content_hash, :string, size: 64, null: false
      add :byte_size, :integer

      add :file_format, :string, size: 20
      # The layout config actually used, copied in at ingestion time.
      #
      # Not a reference to the live config: an operator investigating a file
      # months later needs to know how it *was* parsed, and per-employer layout
      # config changes. Storing the snapshot makes the parse reproducible.
      add :layout_snapshot, :map, default: %{}

      # PARSED    — read and validated, nothing posted
      # POSTING   — batch disbursement in progress
      # COMPLETED — every line reached a terminal state
      # REJECTED  — refused whole, e.g. a duplicate hash
      add :status, :string, size: 20, null: false, default: "PARSED"

      add :line_count, :integer, default: 0
      add :parsed_count, :integer, default: 0
      add :error_count, :integer, default: 0
      add :total_net_amount, :decimal, precision: 18, scale: 4, default: 0
      add :currency, :string, size: 3

      # Per-line parse failures, kept with the file rather than as salary credit
      # rows: a line that would not parse never became a credit.
      add :parse_errors, :map, default: %{}

      add :uploaded_by, :string, size: 100
      add :ingested_at, :utc_datetime_usec
      add :rejected_reason, :string, size: 300

      timestamps(type: :utc_datetime_usec)
    end

    # Deliberately NOT unique. Re-ingesting identical content is governed by
    # `wps.duplicate_file_policy`, which an institution may set to "warn" — and
    # a configurable policy cannot also be an absolute database constraint.
    #
    # The guarantee that actually stops a double payment is the unique index on
    # (employer_id, payment_reference) below. That one is an invariant, not a
    # policy, and it is where the constraint belongs.
    create index(:wps_files, [:employer_id, :content_hash],
             name: :wps_files_employer_hash_idx
           )

    create index(:wps_files, [:employer_id, :status])

    create constraint(:wps_files, :wps_files_status_check,
             check: "status IN ('PARSED','POSTING','COMPLETED','REJECTED')"
           )

    # -------------------------------------------------------------------------

    create table(:wps_salary_credits, primary_key: false) do
      add :salary_credit_id, :binary_id,
          primary_key: true,
          default: fragment("gen_random_uuid()")

      add :wps_file_id,
          references(:wps_files, column: :wps_file_id, type: :binary_id, on_delete: :delete_all),
          null: false

      add :employer_id,
          references(:wps_employers, column: :employer_id, type: :binary_id, on_delete: :restrict),
          null: false

      add :line_number, :integer, null: false

      add :employee_id, :string, size: 60, null: false
      add :employee_name, :string, size: 200

      # The employer's own reference for this payment. The idempotency key for
      # disbursement is derived from it, which is why it is required and why it
      # is unique per employer below.
      add :payment_reference, :string, size: 100, null: false

      add :gross_amount, :decimal, precision: 18, scale: 4
      add :deduction_amount, :decimal, precision: 18, scale: 4
      # What actually gets paid.
      add :net_amount, :decimal, precision: 18, scale: 4, null: false
      add :currency, :string, size: 3, null: false, default: "AED"

      add :pay_period_start, :date
      add :pay_period_end, :date
      add :payment_date, :date

      # Resolved from the roster at pre-flight, not at parse: a worker linked
      # after the file arrived should still be payable on a re-run.
      add :prepaid_account_id, :binary_id

      # PARSED    — read from the file
      # VALIDATED — passed line validation and resolved to an account
      # POSTED    — disbursed
      # FAILED    — could not be disbursed; an exception row explains why
      add :status, :string, size: 20, null: false, default: "PARSED"
      add :failure_reason, :string, size: 300
      add :posted_at, :utc_datetime_usec

      timestamps(type: :utc_datetime_usec)
    end

    # The real idempotency guarantee for disbursement. An employer's payment
    # reference identifies one payment; re-running a batch, or re-sending a
    # corrected file that repeats a reference, must not pay it twice.
    create unique_index(:wps_salary_credits, [:employer_id, :payment_reference],
             name: :wps_salary_credits_payment_ref_idx
           )

    create index(:wps_salary_credits, [:wps_file_id, :status])
    create index(:wps_salary_credits, [:employer_id, :employee_id])
    create index(:wps_salary_credits, [:prepaid_account_id])

    create constraint(:wps_salary_credits, :wps_salary_credits_status_check,
             check: "status IN ('PARSED','VALIDATED','POSTED','FAILED')"
           )

    # Nobody is paid a negative or zero wage. Enforced here because it is the
    # invariant a mis-parsed amount column most often violates.
    create constraint(:wps_salary_credits, :wps_salary_credits_net_positive_check,
             check: "net_amount > 0"
           )
  end
end
