defmodule VmuCore.Repo.Migrations.AddMultiOrgFieldsToBankParameters do
  @moduledoc """
  Sprint 4C: Multi-org isolation fields on bank_parameters.

  - base_currency     — ISO 4217 functional currency (default AED)
  - billing_timezone  — IANA timezone for EOD cutoff and cycle-date logic
  - regulatory_regime — regulatory authority code (CBUAE, CBB, SAMA, etc.)
  - org_name          — human-readable bank name used in Metro 2 header and reports
  """

  use Ecto.Migration

  def change do
    alter table(:bank_parameters) do
      add :base_currency,     :string, size: 3,  default: "AED"
      add :billing_timezone,  :string, size: 50, default: "Asia/Dubai"
      add :regulatory_regime, :string, size: 20, default: "CBUAE"
      add :org_name,          :string, size: 100
    end
  end
end
