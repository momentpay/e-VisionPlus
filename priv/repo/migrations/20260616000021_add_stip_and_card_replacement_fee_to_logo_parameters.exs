defmodule VmuCore.Repo.Migrations.AddStipAndCardReplacementFeeToLogoParameters do
  @moduledoc """
  Sprint 4H + 4F: Add STIP configuration and card_replacement_fee to logo_parameters.

  STIP (Stand-In Processing) allows the authorization system to approve
  transactions when the real-time decision engine is unavailable.

  Fields:
    - stip_enabled       — master switch for STIP on this logo
    - stip_floor_limit   — always approve transactions at or below this amount (AED)
    - stip_max_amount    — never approve transactions above this amount under STIP (AED)
    - card_replacement_fee — fee posted when a card_reissue non-monetary event is recorded (4F)
  """

  use Ecto.Migration

  def change do
    alter table(:logo_parameters) do
      add :stip_enabled,         :boolean, default: false
      add :stip_floor_limit,     :decimal, precision: 18, scale: 2, default: "50.00"
      add :stip_max_amount,      :decimal, precision: 18, scale: 2, default: "500.00"
      add :card_replacement_fee, :decimal, precision: 18, scale: 2, default: "0.00"
    end
  end
end
