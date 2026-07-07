defmodule VmuCore.Repo.Migrations.CreateTramsTransactionTables do
  use Ecto.Migration

  def change do
    # ── Transaction aggregate root (TRAM-P1 1A) ────────────────────────────────
    # System of record for "what happened" to a transaction. State column is a
    # projection maintained by EventStore (ADR-T1); the event log below is the
    # audit source of truth.
    create table(:trams_transactions, primary_key: false) do
      add :transaction_id,       :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,           :uuid  # nullable — declined auths have no resolved account
      add :pan_token,            :string, size: 64, null: false
      add :sys_id,               :string, size: 4
      add :logo_id,              :string, size: 8
      # Merchant inline per ADR-T4 (no merchant master yet)
      add :merchant_id,          :string, size: 15   # DE42
      add :merchant_name,        :string, size: 40   # DE43
      add :mcc,                  :string, size: 4
      add :transaction_type,     :string, size: 20, null: false, default: "PURCHASE"
      # PURCHASE | CASH_ADV | FEE | REVERSAL | ADJUSTMENT
      add :channel,              :string, size: 20
      add :amount,               :decimal, precision: 18, scale: 2, null: false
      add :settled_amount,       :decimal, precision: 18, scale: 2
      add :currency,             :string, size: 3
      add :state,                :string, size: 20, null: false, default: "INITIATED"
      # FAS linkage — unique makes the FAS→TRAM feed idempotent (ADR-T2)
      add :fas_authorization_id, :uuid
      add :clearing_id,          :uuid  # matched trams_clearing_records row
      add :transaction_date,     :utc_datetime  # original purchase datetime
      add :posted_at,            :utc_datetime
      add :statement_date,       :date
      add :closed_at,            :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:trams_transactions, [:fas_authorization_id],
             where: "fas_authorization_id IS NOT NULL")
    create index(:trams_transactions, [:account_id, :inserted_at])
    create index(:trams_transactions, [:pan_token, :inserted_at])
    create index(:trams_transactions, [:state])
    create index(:trams_transactions, [:statement_date])

    # ── Append-only event log (1A) ─────────────────────────────────────────────
    # The most important table in the schema (spec §5.2). Never updated or
    # deleted; unique (transaction_id, seq) enforces strict ordering.
    create table(:trams_transaction_events, primary_key: false) do
      add :event_id,       :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :transaction_id, references(:trams_transactions, column: :transaction_id, type: :uuid),
                           null: false
      add :seq,            :integer, null: false
      add :event_type,     :string, size: 40, null: false
      add :payload,        :map, null: false, default: %{}
      add :actor,          :string, size: 50, null: false, default: "system"
      # network | system | operator ID
      add :occurred_at,    :utc_datetime_usec, null: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:trams_transaction_events, [:transaction_id, :seq])
    create index(:trams_transaction_events, [:event_type])

    # ── External identifiers (spec §6) ─────────────────────────────────────────
    # Business identity (UUID above) vs external identity (STAN/RRN/auth code).
    # One row per identifier source message; a transaction accumulates several.
    create table(:trams_transaction_identifiers, primary_key: false) do
      add :id,             :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :transaction_id, references(:trams_transactions, column: :transaction_id, type: :uuid),
                           null: false
      add :stan,           :string, size: 12
      add :rrn,            :string, size: 12
      add :auth_code,      :string, size: 6
      add :network_ref,    :string, size: 50
      add :source,         :string, size: 20, null: false, default: "authorization"
      # authorization | clearing | dispute

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:trams_transaction_identifiers, [:transaction_id])
    create index(:trams_transaction_identifiers, [:rrn])
    create index(:trams_transaction_identifiers, [:stan])
    create index(:trams_transaction_identifiers, [:auth_code])

    # ── Adjustments (spec 06 §3.4) ─────────────────────────────────────────────
    create table(:trams_adjustments, primary_key: false) do
      add :adjustment_id,  :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :transaction_id, references(:trams_transactions, column: :transaction_id, type: :uuid),
                           null: false
      add :old_amount,     :decimal, precision: 18, scale: 2, null: false
      add :new_amount,     :decimal, precision: 18, scale: 2, null: false
      add :delta,          :decimal, precision: 18, scale: 2, null: false
      add :direction,      :string, size: 6, null: false  # CREDIT | DEBIT
      add :reason_code,    :string, size: 30, null: false
      add :narrative,      :string, size: 255
      add :status,         :string, size: 20, null: false, default: "PENDING_APPROVAL"
      # PENDING_APPROVAL | APPROVED | REJECTED | POSTED
      add :requested_by,   :string, size: 50, null: false
      add :approved_by,    :string, size: 50
      add :gl_idempotency_key, :string, size: 100
      add :posted_at,      :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create index(:trams_adjustments, [:transaction_id])
    create index(:trams_adjustments, [:status])

    # ── Maintenance actions (spec 05) ──────────────────────────────────────────
    create table(:trams_maintenance_actions, primary_key: false) do
      add :id,             :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :transaction_id, references(:trams_transactions, column: :transaction_id, type: :uuid),
                           null: false
      add :action_type,    :string, size: 30, null: false
      # DESCRIPTIVE_CORRECTION | LINKAGE_CORRECTION | STATUS_OVERRIDE | FLAG | REDRIVE
      add :reason_code,    :string, size: 30, null: false
      # DATA_CORRECTION | MATCHING_ERROR | FRAUD_HOLD | MANUAL_REDRIVE | ...
      add :comment,        :string, size: 500
      add :before_values,  :map, default: %{}
      add :after_values,   :map, default: %{}
      add :status,         :string, size: 20, null: false, default: "PENDING_APPROVAL"
      # PENDING_APPROVAL | APPROVED | REJECTED | APPLIED
      add :requested_by,   :string, size: 50, null: false
      add :approved_by,    :string, size: 50
      add :applied_at,     :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create index(:trams_maintenance_actions, [:transaction_id])
    create index(:trams_maintenance_actions, [:status])

    # ── Statement lines (spec 07 §2.3) ─────────────────────────────────────────
    # Transaction-level statement feed — complements CMS's balance-level
    # StatementGenerator. Unique key makes cycle extraction idempotent.
    create table(:trams_statement_lines, primary_key: false) do
      add :id,               :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :transaction_id,   references(:trams_transactions, column: :transaction_id, type: :uuid),
                             null: false
      add :account_id,       :uuid, null: false
      add :statement_date,   :date, null: false
      add :line_type,        :string, size: 20, null: false, default: "PURCHASE"
      # PURCHASE | CASH_ADV | FEE | ADJUSTMENT_CREDIT | ADJUSTMENT_DEBIT | REVERSAL
      add :transaction_date, :date
      add :posting_date,     :date
      add :merchant_name,    :string, size: 40
      add :mcc,              :string, size: 4
      add :amount,           :decimal, precision: 18, scale: 2, null: false
      add :currency,         :string, size: 3
      add :orig_amount,      :decimal, precision: 18, scale: 2  # FX original
      add :orig_currency,    :string, size: 3
      add :fx_rate,          :decimal, precision: 12, scale: 6
      add :reference,        :string, size: 12  # RRN shown to cardholder for disputes
      add :adjustment_flag,  :boolean, null: false, default: false

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:trams_statement_lines, [:transaction_id, :statement_date, :line_type])
    create index(:trams_statement_lines, [:account_id, :statement_date])

    # ── Fix latent IpmPipeline bug + add TRAM linkage to clearing records ──────
    # IpmPipeline inserts with conflict_target: :idempotency_key but the column
    # never existed — would raise on the first real IPM file.
    alter table(:trams_clearing_records) do
      add :idempotency_key,        :string, size: 64
      add :matched_transaction_id, :uuid
    end

    create unique_index(:trams_clearing_records, [:idempotency_key],
             where: "idempotency_key IS NOT NULL")

    # ── Dispute → TRAM linkage (ADR-T5) ────────────────────────────────────────
    alter table(:dps_disputes) do
      add :trams_transaction_id, :uuid
    end

    create index(:dps_disputes, [:trams_transaction_id])
  end
end
