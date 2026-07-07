defmodule VmuCore.Repo.Migrations.ExtendSysBankParameters do
  @moduledoc """
  Sprint 2K + 2L: Extend SYS and BANK control record tables.

  ## SYS additions (global processor-level defaults)

  - batch_controls      : JSONB — EOD batch window, retry limits, job sequencing flags
  - cycle_controls      : JSONB — Default billing cycle day, cycle length days
  - global_status_codes : JSONB array — valid account status codes for this processor
  - posting_rules       : JSONB — posting window, backdating limits, same-day cutoff

  ## BANK additions (institution-level overrides)

  - tax_rule            : JSONB — VAT rate, tax code, exempt categories
  - gl_mapping_profile  : string — identifier for the GL chart-of-accounts profile
  - delinquency_rules   : JSONB — DPD thresholds, COL handoff rules, write-off days
  - settlement_calendar : JSONB — non-working days, settlement cutoff times
  - swift_bic           : string — SWIFT/BIC for settlement messages (11 chars)
  """

  use Ecto.Migration

  def change do
    # ── SYS parameter extensions ───────────────────────────────────────────────
    alter table(:sys_parameters) do
      add :batch_controls,      :map
      add :cycle_controls,      :map
      add :global_status_codes, {:array, :string}
      add :posting_rules,       :map
    end

    # ── BANK parameter extensions ──────────────────────────────────────────────
    alter table(:bank_parameters) do
      add :tax_rule,              :map
      add :gl_mapping_profile,    :string, size: 20
      add :delinquency_rules,     :map
      add :settlement_calendar,   :map
      add :swift_bic,             :string, size: 11
    end
  end
end
