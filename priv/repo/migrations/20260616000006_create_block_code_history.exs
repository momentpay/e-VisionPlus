defmodule VmuCore.Repo.Migrations.CreateBlockCodeHistory do
  @moduledoc """
  Sprint 2A: Audit trail for every block code applied or removed from an account.

  Every operator action that changes block_code on an account must insert a row
  here. This table is append-only — rows are never updated or deleted, providing
  a tamper-evident audit log for compliance and investigations.

  Columns:
    account_id   — the affected CMS account
    block_code   — the code applied (L/S/F/C/O) or nil for 'unblock'
    action       — BLOCKED | UNBLOCKED
    reason_code  — structured reason (REPORTED_LOST, REPORTED_STOLEN, FRAUD_ALERT,
                   COLLECTIONS_HOLD, OVERLIMIT, CUSTOMER_REQUEST, EOD_AUTOMATED, ...)
    reason_text  — free-form operator note (may be blank)
    operator_id  — UUID of the operator or system user who applied the change
    operator_role— AGENT | SUPERVISOR | SYSTEM
    applied_at   — timestamp of the change (UTC)
  """

  use Ecto.Migration

  def change do
    create table(:block_code_history, primary_key: false) do
      add :id,            :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,    references(:cms_accounts, type: :binary_id, column: :account_id,
                            on_delete: :restrict), null: false
      add :block_code,    :string, size: 2       # nil = unblock action
      add :action,        :string, size: 10, null: false  # BLOCKED | UNBLOCKED
      add :reason_code,   :string, size: 40, null: false
      add :reason_text,   :string, size: 200
      add :operator_id,   :binary_id, null: false
      add :operator_role, :string, size: 20, null: false, default: "AGENT"
      add :applied_at,    :naive_datetime, null: false,
                            default: fragment("NOW()")
    end

    # Fast lookup of history for a specific account (most recent first)
    create index(:block_code_history, [:account_id, :applied_at],
             name: :block_code_history_account_idx)

    # Compliance query: all fraud blocks across the system in a date range
    create index(:block_code_history, [:block_code, :applied_at],
             name: :block_code_history_code_date_idx)
  end
end
