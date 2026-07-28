defmodule VmuCore.Repo.Migrations.PrepaidAccountParityFields do
  @moduledoc """
  Card Products UX Parity Phase 2d (2026-07-28) — Prepaid's own copies of
  Debit's Phase 1e retrofit (docs/compare/Card_Products_UX_Parity_Tracker.md
  §6), same 6-item scope applied to `cms_prepaid_accounts`.

  Own tables, own FKs — same reasoning as `cms_debit_block_history`/
  `cms_debit_non_monetary_events`: Credit's `block_code_history`/
  `cms_non_monetary_events` both carry a genuine DB-level FK to
  `cms_accounts` specifically, so a `prepaid_account_id` cannot be
  inserted there either.
  """

  use Ecto.Migration

  def change do
    alter table(:cms_prepaid_accounts) do
      add :block_code,      :string, size: 2
      add :block_reason,    :string, size: 200
      add :blocked_at,      :naive_datetime
      add :velocity_limits, :map, default: %{}
      add :kyc_status,      :string, size: 20, default: "PENDING"
      add :kyc_verified_at, :naive_datetime
    end

    create table(:cms_prepaid_block_history, primary_key: false) do
      add :id,                 :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :prepaid_account_id, references(:cms_prepaid_accounts, type: :binary_id,
                                  column: :prepaid_account_id, on_delete: :restrict), null: false
      add :block_code,         :string, size: 2
      add :action,             :string, size: 10, null: false
      add :reason_code,        :string, size: 40, null: false
      add :reason_text,        :string, size: 200
      add :operator_id,        :binary_id, null: false
      add :operator_role,      :string, size: 20, null: false, default: "AGENT"
      add :applied_at,         :naive_datetime, null: false, default: fragment("NOW()")
    end

    create index(:cms_prepaid_block_history, [:prepaid_account_id, :applied_at],
      name: :cms_prepaid_block_history_account_idx)

    create table(:cms_prepaid_non_monetary_events, primary_key: false) do
      add :id,                 :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :prepaid_account_id, references(:cms_prepaid_accounts, type: :binary_id,
                                  column: :prepaid_account_id, on_delete: :restrict), null: false
      add :event_type,         :string, size: 30, null: false
      add :old_value,          :map
      add :new_value,          :map
      add :reason,             :string, size: 255
      add :reference_id,       :string, size: 50
      add :operator_id,        :binary_id, null: false
      add :operator_role,      :string, size: 20, default: "AGENT"
      add :applied_at,         :naive_datetime, null: false

      timestamps(updated_at: false)
    end

    create index(:cms_prepaid_non_monetary_events, [:prepaid_account_id, :applied_at],
      name: :cms_prepaid_nme_account_time_idx)
  end
end
