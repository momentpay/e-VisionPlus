defmodule VmuCore.Repo.Migrations.CreateWpsEmployerAndRoster do
  @moduledoc """
  WPS (Wage Protection System) employer, worker roster and beneficiary link
  (Phase W1).

  ## Why an employer separate from `hcs_companies`

  They look similar — one organisation, many workers, funded centrally — but
  they are not the same relationship. An HCS company is a **credit** customer:
  it holds a facility, its employees spend against the company's limit, and the
  company owes the bank. A WPS employer is a **disbursement counterparty**: it
  pushes its own money out to workers who are the bank's customers, and owes the
  bank nothing.

  Modelling WPS on `hcs_companies` would mean a `credit_limit` that is never
  used and a liability model that does not apply. They share a shape, not a
  meaning.

  ## The roster is the beneficiary link

  There is no separate "worker" table. A worker who matters to WPS is one with a
  disbursement target, and that is exactly what `wps_beneficiary_links` records:
  the employer's own `employee_id` resolved to a `cms_prepaid_accounts` row.

  An employee id is only unique *within* an employer — two employers may both
  use "001" — so the link is keyed on `(employer_id, employee_id)`, not on the
  employee id alone.
  """
  use Ecto.Migration

  def change do
    create table(:wps_employers, primary_key: false) do
      add :employer_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      # Institution, as every other product table carries it — the posting
      # engine resolves sys_id/bank_id from the account, but employer-level
      # reporting and Module Config both scope by bank.
      add :sys_id, :string, size: 4, null: false
      add :bank_id, :string, size: 4, null: false

      add :employer_code, :string, size: 40, null: false
      add :employer_name, :string, size: 200, null: false

      # The regulator's own identifier for this employer. Named generically
      # because the scheme differs by market: MOHRE issues an establishment ID
      # in the UAE, Saudi and Bahrain use their own. Nullable, because an
      # employer can be onboarded before its registration is confirmed.
      add :regulator_id, :string, size: 60
      add :jurisdiction, :string, size: 8

      # Where the salary money comes from. A funding account is the employer's
      # own settlement account with the bank; absent means the employer funds
      # per-file by external transfer, which is the exchange-house pattern.
      add :funding_account_id, :binary_id

      add :status, :string, size: 20, null: false, default: "ACTIVE"
      add :onboarded_at, :utc_datetime_usec
      add :notes, :string, size: 500

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:wps_employers, [:sys_id, :bank_id, :employer_code],
             name: :wps_employers_code_idx
           )

    # Nullable, so a partial index — several employers may have no regulator id
    # yet, and those must not collide with each other.
    create unique_index(:wps_employers, [:sys_id, :bank_id, :regulator_id],
             name: :wps_employers_regulator_idx,
             where: "regulator_id IS NOT NULL"
           )

    create constraint(:wps_employers, :wps_employers_status_check,
             check: "status IN ('ACTIVE','SUSPENDED','CLOSED')"
           )

    # -------------------------------------------------------------------------

    create table(:wps_beneficiary_links, primary_key: false) do
      add :link_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :employer_id,
          references(:wps_employers, column: :employer_id, type: :binary_id, on_delete: :restrict),
          null: false

      # The employer's own identifier for this worker, as it appears in their
      # salary file. Free-form on purpose: it is their key, not ours.
      add :employee_id, :string, size: 60, null: false
      add :employee_name, :string, size: 200

      # The disbursement target. `WPS_PREPAID` is the product (see the GL
      # rules), so this is a `cms_prepaid_accounts.prepaid_account_id`.
      #
      # No foreign key: `cms_prepaid_accounts` is one of five product account
      # tables addressed by bare binary ids across this codebase, and a link
      # may legitimately be created in an UNVERIFIED state before the account
      # exists. `Roster.link/1` checks existence when the state requires it.
      add :prepaid_account_id, :binary_id

      # UNVERIFIED — recorded from a file, account not yet confirmed
      # ACTIVE     — resolvable, salary credits may post
      # SUSPENDED  — worker left, disputed, or KYC lapsed
      add :status, :string, size: 20, null: false, default: "UNVERIFIED"

      add :linked_by, :string, size: 100
      add :linked_at, :utc_datetime_usec
      add :suspended_reason, :string, size: 200

      timestamps(type: :utc_datetime_usec)
    end

    # An employee id is unique only within its employer.
    create unique_index(:wps_beneficiary_links, [:employer_id, :employee_id],
             name: :wps_beneficiary_links_employee_idx
           )

    # "Which employers pay into this account" — the question asked when a worker
    # changes job, or when one account starts receiving from two employers,
    # which is a real fraud signal rather than an error.
    create index(:wps_beneficiary_links, [:prepaid_account_id])
    create index(:wps_beneficiary_links, [:employer_id, :status])

    create constraint(:wps_beneficiary_links, :wps_beneficiary_links_status_check,
             check: "status IN ('UNVERIFIED','ACTIVE','SUSPENDED')"
           )

    # An ACTIVE link must have somewhere to pay. Enforced in the database
    # because this is the invariant the whole disbursement path depends on:
    # every other check happens per-file, this one cannot be skipped.
    create constraint(:wps_beneficiary_links, :wps_beneficiary_links_active_has_account_check,
             check: "status <> 'ACTIVE' OR prepaid_account_id IS NOT NULL"
           )
  end
end
