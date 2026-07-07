defmodule VmuCore.Repo.Migrations.CreateCmsEmiSchedules do
  @moduledoc """
  Sprint 3B: EMI instalment schedule table.

  Stores the full amortisation schedule for credit card EMI plans —
  one row per instalment per converted transaction. Each row captures
  principal, interest, due date, and payment status.

  The emi_balance field is also added to cms_balance_buckets so the
  EOD pipeline can track outstanding EMI principal separately from
  retail and cash purchase balances.
  """

  use Ecto.Migration

  def change do
    # ── EMI schedule table ────────────────────────────────────────────────────
    create table(:cms_emi_schedules, primary_key: false) do
      add :id,             :binary_id,  primary_key: true
      add :account_id,     references(:cms_accounts,
                             column:    :account_id,
                             type:      :binary_id,
                             on_delete: :restrict
                           ), null: false
      add :plan_id,        :string,     size: 8,  null: false
      add :transaction_id, :binary_id              # originating transaction (may be null for manual EMI)
      add :instalment_no,  :integer,               null: false  # 1-based
      add :tenor_total,    :integer,               null: false  # total number of instalments
      add :due_date,       :date,                  null: false
      add :principal_due,  :decimal, precision: 18, scale: 2, null: false
      add :interest_due,   :decimal, precision: 18, scale: 2, null: false
      add :instalment_due, :decimal, precision: 18, scale: 2, null: false
      add :paid_date,      :date
      add :paid_amount,    :decimal, precision: 18, scale: 2
      add :outstanding,    :decimal, precision: 18, scale: 2, null: false  # remaining principal after
      add :status,         :string,     size: 10, default: "PENDING"

      timestamps()
    end

    # Unique constraint: one row per (account, plan, instalment number)
    create unique_index(:cms_emi_schedules,
      [:account_id, :plan_id, :instalment_no],
      name: :cms_emi_schedules_unique_idx
    )

    # EOD billing query: find pending instalments due by date
    create index(:cms_emi_schedules,
      [:account_id, :due_date, :status],
      name: :cms_emi_schedules_due_idx
    )

    # ── Add emi_balance to balance buckets ────────────────────────────────────
    alter table(:cms_balance_buckets) do
      add :emi_balance, :decimal, precision: 18, scale: 2, default: 0
    end
  end
end
