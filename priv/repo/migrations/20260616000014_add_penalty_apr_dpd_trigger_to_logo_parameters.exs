defmodule VmuCore.Repo.Migrations.AddPenaltyAprDpdTriggerToLogoParameters do
  @moduledoc """
  Sprint 3K: Add penalty APR DPD trigger to logo_parameters.

  `penalty_apr_dpd_trigger` defines the delinquency bucket (DPD) at which
  the penalty APR replaces the standard purchase and cash APRs for interest
  accrual. The default of 60 DPD is a common industry threshold; issuers may
  configure 30, 60, or 90 DPD at the logo level.
  """

  use Ecto.Migration

  def change do
    alter table(:logo_parameters) do
      add :penalty_apr_dpd_trigger, :integer, default: 60
    end
  end
end
