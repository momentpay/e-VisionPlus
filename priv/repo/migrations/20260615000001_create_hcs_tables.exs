defmodule VmuCore.Repo.Migrations.CreateHcsTables do
  use Ecto.Migration

  def change do
    create table(:hcs_companies) do
      add :company_code,         :string, size: 20, null: false
      add :company_name,         :string, size: 200, null: false
      add :registration_no,      :string, size: 50, null: false
      add :tax_id,               :string, size: 50
      add :industry_code,        :string, size: 10
      add :liability_model,      :string, size: 20, null: false   # CENTRAL | INDIVIDUAL
      add :billing_cycle_day,    :integer, null: false, default: 25
      add :credit_limit,         :decimal, precision: 18, scale: 2, null: false
      add :available_limit,      :decimal, precision: 18, scale: 2, null: false
      add :max_employee_cards,   :integer, null: false, default: 50
      add :parent_account_id,    references(:cms_accounts, on_delete: :restrict)
      add :relationship_manager, :string, size: 100
      add :status,               :string, size: 20, null: false, default: "ACTIVE"
      add :kyc_status,           :string, size: 20, null: false, default: "PENDING"
      add :kyc_verified_at,      :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:hcs_companies, [:company_code])
    create index(:hcs_companies, [:status])
    create index(:hcs_companies, [:parent_account_id])

    create table(:hcs_employee_cards) do
      add :company_id,           references(:hcs_companies, on_delete: :restrict), null: false
      add :employee_account_id,  references(:cms_accounts, on_delete: :restrict), null: false
      add :employee_name,        :string, size: 200, null: false
      add :employee_id,          :string, size: 50
      add :department,           :string, size: 100
      add :cost_centre,          :string, size: 50
      add :individual_limit,     :decimal, precision: 18, scale: 2, null: false
      add :available_individual, :decimal, precision: 18, scale: 2, null: false
      add :card_type,            :string, size: 20, null: false, default: "STANDARD"
      add :can_withdraw_cash,    :boolean, null: false, default: false
      add :monthly_spend_cap,    :decimal, precision: 18, scale: 2
      add :status,               :string, size: 20, null: false, default: "ACTIVE"
      add :issued_at,            :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:hcs_employee_cards, [:company_id, :employee_account_id])
    create index(:hcs_employee_cards, [:company_id, :status])
    create index(:hcs_employee_cards, [:employee_account_id])

    create table(:hcs_spending_controls) do
      add :scope,            :string, size: 15, null: false      # COMPANY | EMPLOYEE
      add :company_id,       references(:hcs_companies, on_delete: :restrict), null: false
      add :employee_card_id, references(:hcs_employee_cards, on_delete: :restrict)
      add :control_type,     :string, size: 30, null: false
      add :mcc_codes,        {:array, :string}, default: []
      add :channels,         {:array, :string}, default: []
      add :daily_cap,        :decimal, precision: 18, scale: 2
      add :per_txn_cap,      :decimal, precision: 18, scale: 2
      add :effective_from,   :date, null: false
      add :effective_to,     :date
      add :status,           :string, size: 20, null: false, default: "ACTIVE"
      add :inserted_at,      :utc_datetime, null: false
    end

    create index(:hcs_spending_controls, [:company_id, :scope, :status])

    create table(:hcs_consolidated_statements) do
      add :company_id,       references(:hcs_companies, on_delete: :restrict), null: false
      add :statement_date,   :date, null: false
      add :period_from,      :date, null: false
      add :period_to,        :date, null: false
      add :total_spend,      :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :total_payments,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :total_fees,       :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :total_interest,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :closing_balance,  :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :minimum_payment,  :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :payment_due_date, :date, null: false
      add :employee_count,   :integer, null: false, default: 0
      add :file_path,        :string, size: 500
      add :status,           :string, size: 20, null: false, default: "GENERATED"
      add :inserted_at,      :utc_datetime, null: false
    end

    create unique_index(:hcs_consolidated_statements, [:company_id, :statement_date])

    create table(:hcs_payment_sweeps) do
      add :company_id,          references(:hcs_companies, on_delete: :restrict), null: false
      add :sweep_date,          :date, null: false
      add :total_swept,         :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :employee_card_count, :integer, null: false, default: 0
      add :status,              :string, size: 20, null: false, default: "PENDING"
      add :gl_entry_id,         :bigint
      add :inserted_at,         :utc_datetime, null: false
    end

    create index(:hcs_payment_sweeps, [:company_id, :sweep_date])

    create table(:hcs_payment_sweep_lines) do
      add :sweep_id,         references(:hcs_payment_sweeps, on_delete: :restrict), null: false
      add :employee_card_id, references(:hcs_employee_cards, on_delete: :restrict), null: false
      add :swept_amount,     :decimal, precision: 18, scale: 2, null: false
      add :status,           :string, size: 20, null: false, default: "PENDING"
      add :inserted_at,      :utc_datetime, null: false
    end

    create index(:hcs_payment_sweep_lines, [:sweep_id])
  end
end
