defmodule VmuCore.CMS.ConfigCatalog do
  @moduledoc """
  CMS module configuration catalog — currently covers cycle resegmentation
  (FR-058) as bank-configurable policy rather than hardcoded rules, since
  notice periods, rebalancing cadence, and allowed billing dates are the
  kind of thing that genuinely differs by region/regulatory regime (e.g.
  advance-notice-of-billing-date-change requirements). See
  `VmuCore.CMS.CycleResegmentation` and `VmuCore.Shared.ModuleConfigCatalog`.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "resegmentation_mode",
        module: "cms",
        type: :enum,
        allowed: ~w[manual auto],
        default: "manual",
        scope: :bank,
        description:
          "\"manual\": ops reviews a proposed rebalance and applies it explicitly. " <>
            "\"auto\": the daily EOD pipeline proposes and schedules a rebalance on " <>
            "its own when imbalance exceeds resegmentation_rebalance_threshold_pct. " <>
            "Defaults to manual — the safer starting point for a new capability."
      },
      %{
        key: "resegmentation_notice_days",
        module: "cms",
        type: :integer,
        allowed: nil,
        default: 30,
        scope: :bank,
        description:
          "Minimum advance notice, in days, before a scheduled cycle_code change " <>
            "takes effect on an existing account. A resegmentation is never applied " <>
            "instantly — it's scheduled for today + this many days. Regulatory " <>
            "billing-date-change notice requirements vary by market; set per bank."
      },
      %{
        key: "resegmentation_min_interval_months",
        module: "cms",
        type: :integer,
        allowed: nil,
        default: 12,
        scope: :bank,
        description:
          "Minimum months that must pass since an account's last cycle_code change " <>
            "before it's eligible to be resegmented again. Prevents repeated " <>
            "billing-date churn for the same cardholder."
      },
      %{
        key: "resegmentation_rebalance_threshold_pct",
        module: "cms",
        type: :integer,
        allowed: nil,
        default: 20,
        scope: :bank,
        description:
          "How far a cycle_code's account count may exceed the even-distribution " <>
            "average (as a percentage) before VmuCore.CMS.CycleResegmentation.propose_rebalance/3 " <>
            "flags it as imbalanced and proposes moving accounts off it."
      },
      %{
        key: "allowed_cycle_codes",
        module: "cms",
        type: :list,
        allowed: nil,
        default: [],
        scope: :bank,
        description:
          "Restricts which statement days (1-31) are valid billing dates for this " <>
            "bank — e.g. excluding month-end days some markets don't permit as a " <>
            "billing date. Empty list = unrestricted (all 1-31 allowed, matching " <>
            "the existing EOD scheduler's own end-of-month overflow handling)."
      },
      %{
        key: "resegmentation_proration_method",
        module: "cms",
        type: :enum,
        allowed: ~w[prorate full_short_cycle full_long_cycle],
        default: "prorate",
        scope: :bank,
        description:
          "How the transition billing period (the one cycle spanning the old and " <>
            "new cycle_code) should be handled. Captured on the account at schedule " <>
            "time for audit — a later config change can't silently alter what was " <>
            "already committed to the cardholder. NOTE: capturing this value is " <>
            "built; the interest engine (AccrueInterestJob) does not yet consume it " <>
            "to adjust its day-count math across a resegmentation boundary — flagged " <>
            "in VmuCore.CMS.CycleResegmentation's moduledoc as explicit follow-up, " <>
            "not silently missing."
      }
    ]
  end
end
