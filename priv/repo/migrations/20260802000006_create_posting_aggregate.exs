defmodule VmuCore.Repo.Migrations.CreatePostingAggregate do
  @moduledoc """
  GL Phase A3 — the Posting aggregate (Koṣa DOC-109).

      PostingSet          one financial execution (WAY4's macrotransaction)
        └── PostingEntry  one balanced Dr/Cr posting within it
              └── PostingLeg   one directional movement

  Plus `journal_entries` — the subledger, one row per product-account
  movement (WAY4's GL_TRACE).

  ## The four dates

  Carried on the set, per `docs/gl/GL_Module_Design_and_Plan.md` §4.3. Today
  `cms_ledger_entries` has `posting_date` and `value_date` only, which cannot
  express a reversal: a reversal takes the *original* transaction's
  posting_date but lands on the GL at the *current* banking date.

  ## Balance enforcement

  Double entry is enforced by a DEFERRABLE constraint trigger, not by the
  changeset. A CHECK constraint cannot express it — the invariant spans rows.
  Deferred to COMMIT so a set can be built up leg by leg inside a
  transaction and is only required to balance when that transaction commits.

  Nothing writes these tables yet.
  """
  use Ecto.Migration

  def up do
    # -- PostingSet: the aggregate root ---------------------------------------
    create table(:posting_sets, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :event_type,      :string, size: 30, null: false
      add :product,         :string, size: 20, null: false
      add :posting_rule_id, references(:posting_rules, on_delete: :restrict)

      # The product account this execution belongs to. Deliberately a bare
      # string with no FK: it addresses cms_accounts / cms_debit_accounts /
      # cms_prepaid_accounts / cms_wallet_accounts, which do not share a key
      # type — the same constraint cms_arrangements.account_ref already has.
      add :account_ref, :string, null: false

      add :idempotency_key, :string, null: false
      add :status,          :string, size: 20, null: false, default: "DRAFT"
      add :currency,        :string, size: 3,  null: false, default: "AED"
      add :total_amount,    :decimal, precision: 18, scale: 4, null: false

      # The four dates (§4.3). transaction_date is nullable — internally
      # generated executions such as interest accrual have no external
      # transaction behind them.
      add :transaction_date, :date
      add :posting_date,     :date, null: false
      add :gl_date,          :date, null: false
      add :banking_date,     :date, null: false

      add :narrative,      :string
      add :source_module,  :string, size: 40, null: false
      add :correlation_id, :string

      # Set on the compensating set when this one is reversed, and vice versa.
      add :reverses_id, references(:posting_sets, type: :binary_id, on_delete: :restrict)

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:posting_sets, [:idempotency_key])
    create index(:posting_sets, [:account_ref, :posting_date])
    create index(:posting_sets, [:gl_date])
    create index(:posting_sets, [:status], where: "status <> 'POSTED'", name: :posting_sets_open_idx)

    create constraint(:posting_sets, :posting_sets_status_check,
             check: "status IN ('DRAFT','POSTED','REVERSED','FAILED')")

    create constraint(:posting_sets, :posting_sets_amount_positive_check,
             check: "total_amount > 0")

    # -- PostingEntry ----------------------------------------------------------
    create table(:posting_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :posting_set_id,
          references(:posting_sets, type: :binary_id, on_delete: :delete_all), null: false

      add :sequence,  :integer, null: false
      add :amount,    :decimal, precision: 18, scale: 4, null: false
      add :currency,  :string, size: 3, null: false
      add :narrative, :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:posting_entries, [:posting_set_id, :sequence])
    create constraint(:posting_entries, :posting_entries_amount_positive_check,
             check: "amount > 0")

    # -- PostingLeg ------------------------------------------------------------
    create table(:posting_legs, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :posting_entry_id,
          references(:posting_entries, type: :binary_id, on_delete: :delete_all), null: false

      add :direction,  :string, size: 6, null: false      # debit | credit
      add :gl_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false
      add :amount,     :decimal, precision: 18, scale: 4, null: false
      add :currency,   :string, size: 3, null: false

      timestamps(type: :utc_datetime_usec)
    end

    create index(:posting_legs, [:posting_entry_id])
    create index(:posting_legs, [:gl_account])

    create constraint(:posting_legs, :posting_legs_direction_check,
             check: "direction IN ('debit','credit')")
    create constraint(:posting_legs, :posting_legs_amount_positive_check,
             check: "amount > 0")

    # -- Journal entries: the subledger (WAY4 GL_TRACE) ------------------------
    create table(:journal_entries, primary_key: false) do
      add :id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")

      add :posting_set_id,
          references(:posting_sets, type: :binary_id, on_delete: :restrict), null: false
      add :posting_entry_id,
          references(:posting_entries, type: :binary_id, on_delete: :restrict), null: false

      add :account_ref, :string, null: false
      add :product,     :string, size: 20, null: false

      add :dr_gl_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false
      add :cr_gl_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false

      add :amount,   :decimal, precision: 18, scale: 4, null: false
      add :currency, :string, size: 3, null: false

      add :transaction_date, :date
      add :posting_date,     :date, null: false
      add :gl_date,          :date, null: false

      add :narrative, :string

      timestamps(type: :utc_datetime_usec)
    end

    create index(:journal_entries, [:account_ref, :posting_date])
    create index(:journal_entries, [:posting_set_id])
    create index(:journal_entries, [:gl_date])

    create constraint(:journal_entries, :journal_entries_distinct_accounts_check,
             check: "dr_gl_account <> cr_gl_account")
    create constraint(:journal_entries, :journal_entries_amount_positive_check,
             check: "amount > 0")

    # -- Double-entry enforcement ---------------------------------------------
    # Deferred to COMMIT: a set is assembled leg by leg, so it is legitimately
    # unbalanced mid-transaction. It must balance by the time the transaction
    # commits — per entry (debits = credits) and per entry against its own
    # declared amount.
    execute """
    CREATE OR REPLACE FUNCTION posting_entry_must_balance() RETURNS TRIGGER AS $$
    DECLARE
      v_entry_id  uuid;
      v_debit     numeric(18,4);
      v_credit    numeric(18,4);
      v_declared  numeric(18,4);
    BEGIN
      v_entry_id := COALESCE(NEW.posting_entry_id, OLD.posting_entry_id);

      SELECT amount INTO v_declared FROM posting_entries WHERE id = v_entry_id;

      -- Entry deleted in the same transaction: nothing left to balance.
      IF v_declared IS NULL THEN
        RETURN NULL;
      END IF;

      SELECT
        COALESCE(SUM(amount) FILTER (WHERE direction = 'debit'), 0),
        COALESCE(SUM(amount) FILTER (WHERE direction = 'credit'), 0)
      INTO v_debit, v_credit
      FROM posting_legs
      WHERE posting_entry_id = v_entry_id;

      IF v_debit <> v_credit THEN
        RAISE EXCEPTION
          'posting entry % is unbalanced: debits %, credits %', v_entry_id, v_debit, v_credit
          USING ERRCODE = 'check_violation';
      END IF;

      IF v_debit <> v_declared THEN
        RAISE EXCEPTION
          'posting entry % legs total % but the entry declares %', v_entry_id, v_debit, v_declared
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE CONSTRAINT TRIGGER posting_legs_balance_trigger
    AFTER INSERT OR UPDATE OR DELETE ON posting_legs
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION posting_entry_must_balance();
    """

    # An entry with no legs at all is never valid. Checked at COMMIT on the
    # entry itself, since the leg trigger cannot fire for legs that were
    # never inserted.
    execute """
    CREATE OR REPLACE FUNCTION posting_entry_must_have_legs() RETURNS TRIGGER AS $$
    DECLARE
      v_count integer;
    BEGIN
      SELECT count(*) INTO v_count FROM posting_legs WHERE posting_entry_id = NEW.id;

      IF v_count = 0 THEN
        RAISE EXCEPTION 'posting entry % has no legs', NEW.id
          USING ERRCODE = 'check_violation';
      END IF;

      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """

    execute """
    CREATE CONSTRAINT TRIGGER posting_entries_have_legs_trigger
    AFTER INSERT ON posting_entries
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION posting_entry_must_have_legs();
    """
  end

  def down do
    execute "DROP TRIGGER IF EXISTS posting_entries_have_legs_trigger ON posting_entries"
    execute "DROP TRIGGER IF EXISTS posting_legs_balance_trigger ON posting_legs"
    execute "DROP FUNCTION IF EXISTS posting_entry_must_have_legs()"
    execute "DROP FUNCTION IF EXISTS posting_entry_must_balance()"

    drop table(:journal_entries)
    drop table(:posting_legs)
    drop table(:posting_entries)
    drop table(:posting_sets)
  end
end
