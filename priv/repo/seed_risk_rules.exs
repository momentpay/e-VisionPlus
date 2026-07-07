# Seeds starter mw_risk activation rules for VmuCore.FAS.RiskAdapter (FAS-P2).
#
# Run with: mix run priv/repo/seed_risk_rules.exs
#
# Tenant IDs are mapped from vmu_core's alpha sys_id codes via
# Application.get_env(:vmu_core, :mw_risk_tenant_ids) — see config/config.exs
# and VmuCore.FAS.RiskAdapter.resolve_tenant_id/1 for why mw_risk needs an
# integer tenant_id even though vMu's own sys_id is alpha (e.g. "MMPD").
#
# Only threshold-type rules are seeded here, not list-type — InfraRepo.Schemas.
# RiskActivationRule declares `list_values` as `{:array, :string}` but the
# migrated column is `jsonb` (mw-core's own pre-existing schema/migration
# mismatch, not introduced here); avoiding rule_type "list" sidesteps it.

alias InfraRepo.Repo
alias InfraRepo.Schemas.RiskActivationRule

now = DateTime.utc_now() |> DateTime.truncate(:second)

tenant_ids = Application.get_env(:vmu_core, :mw_risk_tenant_ids, %{})

rules = [
  %{
    name: "High value transaction",
    description: "Single-transaction amount above 5,000 in transaction currency",
    rule_type: "threshold", entity_type: "transaction", feature_key: "amount",
    operator: ">", threshold_value: 5_000.0, decision: "review", priority: 100
  },
  %{
    name: "Very high value transaction",
    description: "Single-transaction amount above 20,000 in transaction currency",
    rule_type: "threshold", entity_type: "transaction", feature_key: "amount",
    operator: ">", threshold_value: 20_000.0, decision: "decline", priority: 20
  },
  %{
    name: "Gambling MCC",
    description: "MCC 7995 (betting/wagering/gambling) — review every transaction",
    rule_type: "threshold", entity_type: "transaction", feature_key: "mcc",
    operator: "==", threshold_value: 7995.0, decision: "review", priority: 50
  },
  %{
    name: "Card velocity — elevated 1h transaction count",
    description: "More than 5 authorizations on the same card within 1 hour",
    rule_type: "threshold", entity_type: "card", feature_key: "card:1h:count_tx",
    operator: ">", threshold_value: 5.0, decision: "review", priority: 60
  },
  %{
    name: "Card velocity — excessive 1d transaction count",
    description: "More than 20 authorizations on the same card within 1 day",
    rule_type: "threshold", entity_type: "card", feature_key: "card:1d:count_tx",
    operator: ">", threshold_value: 20.0, decision: "decline", priority: 30
  }
]

for {sys_id, tenant_id} <- tenant_ids do
  IO.puts("==> Seeding mw_risk activation rules for sys_id=#{sys_id} (tenant_id=#{tenant_id})")

  for attrs <- rules do
    attrs = Map.merge(attrs, %{tenant_id: tenant_id})

    existing =
      Repo.get_by(RiskActivationRule, tenant_id: tenant_id, name: attrs.name)

    case existing do
      nil ->
        %RiskActivationRule{}
        |> RiskActivationRule.changeset(attrs)
        |> Repo.insert!()

      _record ->
        IO.puts("    skip (already exists): #{attrs.name}")
    end
  end
end

_ = now
IO.puts("==> Done.")
