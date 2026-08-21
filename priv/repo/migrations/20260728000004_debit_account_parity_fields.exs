defmodule VmuCore.Repo.Migrations.DebitAccountParityFields do
  @moduledoc """
  Card Products UX Parity Phase 1e (2026-07-28) — the confirmed scope
  correction in docs/compare/Card_Products_UX_Parity_Tracker.md §6.
  Adds Debit's own parallel copies of Credit's account-level Block,
  velocity limits, and KYC fields, plus two new audit tables
  (`cms_debit_block_history`, `cms_debit_non_monetary_events`) mirroring
  `block_code_history`/`cms_non_monetary_events` exactly.

  Deliberately NOT reusing Credit's own audit tables — both carry a
  genuine DB-level FK to `cms_accounts` specifically (confirmed by
  reading their migrations before this one was written), so a
  `debit_account_id` cannot be inserted there. Own tables, own FKs, same
  shape — consistent with how `cms_debit_adjustments` was already built
  as its own table rather than extending `cms_debit_fundings`.
  """

  use Ecto.Migration

  def change do
    alter table(:cms_debit_accounts) do
      add :block_code,      :string, size: 2
      add :block_reason,    :string, size: 200
      add :blocked_at,      :naive_datetime
      add :velocity_limits, :map, default: %{}
      add :kyc_status,      :string, size: 20, default: "PENDING"
      add :kyc_verified_at, :naive_datetime
    end

    create table(:cms_debit_block_history, primary_key: false) do
      add :id,               :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :debit_account_id, references(:cms_debit_accounts, type: :binary_id,
                                column: :debit_account_id, on_delete: :restrict), null: false
      add :block_code,       :string, size: 2
      add :action,           :string, size: 10, null: false
      add :reason_code,      :string, size: 40, null: false
      add :reason_text,      :string, size: 200
      add :operator_id,      :binary_id, null: false
      add :operator_role,    :string, size: 20, null: false, default: "AGENT"
      add :applied_at,       :naive_datetime, null: false, default: fragment("NOW()")
    end

    create index(:cms_debit_block_history, [:debit_account_id, :applied_at],
      name: :cms_debit_block_history_account_idx)

    create table(:cms_debit_non_monetary_events, primary_key: false) do
      add :id,               :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :debit_account_id, references(:cms_debit_accounts, type: :binary_id,
                                column: :debit_account_id, on_delete: :restrict), null: false
      add :event_type,       :string, size: 30, null: false
      add :old_value,        :map
      add :new_value,        :map
      add :reason,           :string, size: 255
      add :reference_id,     :string, size: 50
      add :operator_id,      :binary_id, null: false
      add :operator_role,    :string, size: 20, default: "AGENT"
      add :applied_at,       :naive_datetime, null: false

      timestamps(updated_at: false)
    end

    create index(:cms_debit_non_monetary_events, [:debit_account_id, :applied_at],
      name: :cms_debit_nme_account_time_idx)
  end
end
