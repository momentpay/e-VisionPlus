defmodule VmuCore.Repo.Migrations.AddLogoExtendedFields do
  use Ecto.Migration

  def change do
    alter table(:logo_parameters) do
      add :card_scheme,                    :string
      add :product_type,                   :string
      add :interest_calculation_method,    :string, default: "AVERAGE_DAILY_BALANCE"
      add :min_payment_calculation,        :string, default: "PERCENTAGE_OF_BALANCE"
      add :annual_fee_posting,             :string, default: "UPON_ACTIVATION"
      add :payment_due_days,               :integer, default: 25
      add :overlimit_allowed,              :boolean, default: false
      add :overlimit_tolerance_pct,        :decimal, precision: 8, scale: 4, default: 0
      add :cash_advance_fee_percent,       :decimal, precision: 8, scale: 4, default: 0
      add :cash_advance_fee_min,           :decimal, precision: 15, scale: 2, default: 0
      add :foreign_transaction_fee_percent, :decimal, precision: 8, scale: 4, default: 0
      add :recurring_enabled,              :boolean, default: true
      add :moto_enabled,                   :boolean, default: false
      add :chip_enabled,                   :boolean, default: true
      add :mag_stripe_enabled,             :boolean, default: true
      add :pin_required,                   :boolean, default: true
      add :card_validity_years,            :integer, default: 3
      add :supplementary_cards_allowed,    :boolean, default: true
      add :supplementary_card_limit,       :integer, default: 3
      add :quasi_cash_enabled,             :boolean, default: false
      add :cash_back_enabled,              :boolean, default: false
      add :credit_limit_min,               :decimal, precision: 15, scale: 2
    end

    alter table(:bank_parameters) do
      add :org_type, :string, default: "BANK"
    end
  end
end
