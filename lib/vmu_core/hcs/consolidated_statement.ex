defmodule VmuCore.HCS.ConsolidatedStatement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_consolidated_statements" do
    field :company_id,       :integer
    field :statement_date,   :date
    field :period_from,      :date
    field :period_to,        :date
    field :total_spend,      :decimal, default: 0
    field :total_payments,   :decimal, default: 0
    field :total_fees,       :decimal, default: 0
    field :total_interest,   :decimal, default: 0
    field :closing_balance,  :decimal, default: 0
    field :minimum_payment,  :decimal, default: 0
    field :payment_due_date, :date
    field :employee_count,   :integer, default: 0
    field :file_path,        :string
    field :status,           :string, default: "GENERATED"
    field :inserted_at,      :utc_datetime
  end

  def changeset(stmt, attrs) do
    stmt
    |> cast(attrs, [:company_id, :statement_date, :period_from, :period_to,
                    :total_spend, :total_payments, :total_fees, :total_interest,
                    :closing_balance, :minimum_payment, :payment_due_date,
                    :employee_count, :file_path, :status, :inserted_at])
    |> validate_required([:company_id, :statement_date, :period_from, :period_to, :payment_due_date])
    |> unique_constraint([:company_id, :statement_date])
  end
end
