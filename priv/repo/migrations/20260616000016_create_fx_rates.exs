defmodule VmuCore.Repo.Migrations.CreateFxRates do
  @moduledoc """
  Sprint 4A: FX rates table for multi-currency conversion.

  Each row is a point-in-time rate for a currency pair. The FxEngine
  always uses the latest rate with effective_date <= requested_date.

  Rates are stored as multipliers: amount_in_from_currency * rate = amount_in_to_currency.
  """

  use Ecto.Migration

  def change do
    create table(:fx_rates, primary_key: false) do
      add :rate_id,        :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :from_currency,  :string, size: 3, null: false
      add :to_currency,    :string, size: 3, null: false
      add :rate,           :decimal, precision: 18, scale: 8, null: false
      add :effective_date, :date, null: false
      add :source,         :string, size: 50   # e.g. "ECB", "MANUAL", "SWIFT"
      add :bank_id,        :string, size: 20   # NULL = applies to all banks

      timestamps()
    end

    # Latest-rate lookup: from + to + effective_date DESC
    create index(:fx_rates, [:from_currency, :to_currency, :effective_date],
      name: :fx_rates_pair_date_idx)

    # Bank-scoped lookup
    create index(:fx_rates, [:bank_id, :from_currency, :to_currency, :effective_date],
      name: :fx_rates_bank_pair_date_idx)
  end
end
