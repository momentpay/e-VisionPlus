defmodule VmuCore.Repo.Migrations.AddDailySpendToHcsEmployeeCards do
  use Ecto.Migration

  @moduledoc """
  F1.1 (2026-07-12) — DAILY_CAP was a documented, schema-valid
  SpendingControl type with zero enforcement (LimitController.apply_control/4
  had no clause for it). Fixing that needs somewhere to track today's
  cumulative spend per card; reusing the same real-time mutation choke
  point (debit_limits/2, credit_limits/2) that already maintains
  available_individual/available_limit, rather than a separate ledger-sum
  query, to avoid a second source of truth.
  """

  def change do
    alter table(:hcs_employee_cards) do
      add :daily_spend, :decimal, null: false, default: 0
      add :daily_spend_date, :date
    end
  end
end
