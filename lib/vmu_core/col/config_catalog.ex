defmodule VmuCore.COL.ConfigCatalog do
  @moduledoc """
  COL module configuration catalog — resolves the open questions in
  `docs/col/COL_Module_Requirements.md` §6 as configurable settings rather than
  hardcoded defaults. See `VmuCore.Shared.ModuleConfigCatalog`.

  `bucket_strategy_matrix` is scoped to `:logo` (product/BIN-range level, per the
  SYS→BANK→LOGO→BLOCK hierarchy) rather than the market-code map shape originally
  pasted into §6 — that pasted example actually described a payment-allocation
  waterfall (FR-CMS concern), not FR-COL-011's ordered treatment-step engine
  (SMS day 3, call day 7, letter day 15, ...). The default value here mirrors the
  ladder currently hardcoded in `CollectionQueueJob.queue_for_dpd/1` and
  `DunningJob.notice_for_dpd/1` / `channels_for_dpd/1` so it's a faithful starting
  point once those jobs are wired to read from here (not yet done — see the COL
  tracker).

  `writeoff_approval_matrix`'s allowed values are real `VmuCore.ASM.Operator` roles
  (TELLER/CS_AGENT/OPS/SUPERVISOR/RISK/COMPLIANCE/ADMIN) — the pasted §6 example used
  invented role names ("risk_head", "branch_manager", ...) that don't exist in this
  system's role taxonomy; corrected during COL-P2 wiring (`VmuCore.COL.WriteOffCommand`).

  COL-P2 wired `writeoff_dpd_threshold`/`writeoff_approval_matrix`/`writeoff_ifrs9_stage`
  (auto write-off trigger + maker-checker approval) and the `contact_cap_*` keys
  (contact-attempt tracking + dunning gate).

  COL-P3 wired `bucket_strategy_matrix` into `DunningJob`. Doing so surfaced (and
  fixed) that the P1 default's `day` values (3/30/60/90, taken literally from
  FR-011's illustrative text "SMS day 3, call day 7...") could never actually match
  anything: `AgeBucketsJob`'s DPD ladder only ever produces the values
  `[0, 30, 60, 90, 120, 150, 180]` — there is no continuous day counter in this
  system, only 30-day bucket jumps. The default below now uses `day` values aligned
  to that real ladder (and a `channels` list per step instead of one row per
  channel), matching exactly what `DunningJob` used to hardcode. See the tracker's
  COL-P3 entry for the full correction and the related `AgeBucketsJob`/
  `CollectionQueueJob` trigger-cadence fix (COL handoff used to only fire at 120+
  DPD, so the 30/60/90 steps were unreachable dead code even after wiring).

  COL-P4 wired `agency_config` into `VmuCore.COL.AgencyDesk` (placement/recall,
  assignment-file generation, activity-file import, commission calculation).

  COL-P6 added a `"queue"` field to each `bucket_strategy_matrix` step so
  `CollectionQueueJob.queue_for_dpd/1` (FR-COL-003) reads the same per-bucket
  list as `DunningJob` (FR-COL-011) via the shared `VmuCore.COL.BucketStrategy`
  lookup, instead of its own separate hardcoded ranges.

  COL-P9 added `workout_approval_matrix` (FR-014) and `settlement_authority_matrix`
  / `settlement_min_acceptable_percent` (FR-015) for `VmuCore.COL.WorkoutCommand` /
  `SettlementCommand`. `settlement_authority_matrix` is a tiered-by-discount-size
  matrix (mirrors `TRAMS.AdjustmentCommand`'s authority-limit shape, but by discount
  percent rather than dollar amount) rather than a flat role list, since FR-015
  explicitly asks for an "authority matrix" — bigger discounts need higher
  authority to approve.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "bucket_strategy_matrix",
        module: "col",
        type: :map,
        allowed: nil,
        default: %{
          "default" => [
            %{"day" => 30, "notice_type" => "soft_reminder", "channels" => ["sms", "email"],
              "queue" => "EARLY_COLLECTIONS"},
            %{"day" => 60, "notice_type" => "formal_notice", "channels" => ["email", "letter"],
              "queue" => "COLLECTIONS"},
            %{"day" => 90, "notice_type" => "demand_letter", "channels" => ["letter", "courier"],
              "queue" => "SENIOR_COLLECTIONS"},
            %{"day" => 120, "notice_type" => "legal_notice",
              "channels" => ["letter", "courier", "registered_mail"], "queue" => "EXTERNAL_AGENCY"}
          ]
        },
        scope: :logo,
        description:
          "Ordered collection treatment steps per product/segment: at each DPD bucket " <>
            "(\"day\"), which notice type/channels fire (FR-011) and which collector queue " <>
            "the case routes to (FR-003, \"queue\"). Keyed by segment name, with \"default\" " <>
            "as the fallback ladder. Both DunningJob and CollectionQueueJob pick the entry " <>
            "with the largest day <= the account's current DPD (so bucket values past the " <>
            "last defined day, e.g. 150/180, reuse that last entry as a catch-all)."
      },
      %{
        key: "agency_config",
        module: "col",
        type: :map,
        allowed: nil,
        default: %{},
        scope: :bank,
        description:
          "Per-agency file format (\"file_format\": CSV/JSON/XML), commission terms " <>
            "(\"commission_type\": flat_percent/fixed_fee/tiered_percent + \"commission_value\"), " <>
            "and an optional field mapper (\"import_mapping\"/\"activity_type_map\"/" <>
            "\"date_format\"/\"export_mapping\") for agencies whose file layout differs " <>
            "from this repo's own field names/vocabulary/date format — absent means " <>
            "identity, no config needed for an agency that already matches. Keyed by " <>
            "agency code. See VmuCore.COL.AgencyDesk moduledoc for the exact shape."
      },
      %{
        key: "writeoff_dpd_threshold",
        module: "col",
        type: :integer,
        allowed: nil,
        default: 180,
        scope: :bank,
        description: "DPD at which an account becomes eligible for automatic write-off."
      },
      %{
        key: "writeoff_approval_matrix",
        module: "col",
        type: :list,
        allowed: ~w[TELLER CS_AGENT OPS SUPERVISOR RISK COMPLIANCE ADMIN],
        default: ["RISK"],
        scope: :bank,
        description:
          "ASM operator roles (see VmuCore.ASM.Operator.roles/0) allowed to approve a " <>
            "write-off request. ADMIN can always approve regardless of this list."
      },
      %{
        key: "writeoff_ifrs9_stage",
        module: "col",
        type: :enum,
        allowed: ~w[Stage1 Stage2 Stage3],
        default: "Stage3",
        scope: :bank,
        description: "IFRS9 provisioning stage applied at write-off."
      },
      %{
        key: "contact_cap_sms_per_day",
        module: "col",
        type: :integer,
        allowed: nil,
        default: 3,
        scope: :bank,
        description: "Regulatory maximum SMS contact attempts per day per account."
      },
      %{
        key: "contact_cap_calls_per_week",
        module: "col",
        type: :integer,
        allowed: nil,
        default: 5,
        scope: :bank,
        description: "Regulatory maximum phone-call contact attempts per week per account."
      },
      %{
        key: "contact_cap_emails_per_week",
        module: "col",
        type: :integer,
        allowed: nil,
        default: 2,
        scope: :bank,
        description: "Regulatory maximum email contact attempts per week per account."
      },
      %{
        key: "contact_cooloff_hours",
        module: "col",
        type: :integer,
        allowed: nil,
        default: 0,
        scope: :bank,
        description: "Minimum hours required between two contact attempts on the same account, regardless of channel."
      },
      %{
        key: "workout_approval_matrix",
        module: "col",
        type: :list,
        allowed: ~w[TELLER CS_AGENT OPS SUPERVISOR RISK COMPLIANCE ADMIN],
        default: ["SUPERVISOR"],
        scope: :bank,
        description:
          "ASM operator roles allowed to approve a hardship/workout plan (restructure, " <>
            "APR reduction, payment holiday). ADMIN can always approve."
      },
      %{
        key: "settlement_authority_matrix",
        module: "col",
        type: :map,
        allowed: nil,
        default: %{
          "tiers" => [
            %{"max_discount_percent" => 10, "role" => "SUPERVISOR"},
            %{"max_discount_percent" => 25, "role" => "RISK"},
            %{"max_discount_percent" => 100, "role" => "ADMIN"}
          ]
        },
        scope: :bank,
        description:
          "Tiered approval authority for settlement offers, by discount size: the " <>
            "approver's role must appear in the first tier (ascending max_discount_percent) " <>
            "whose max_discount_percent >= the offer's discount_percent. ADMIN always qualifies."
      },
      %{
        key: "settlement_min_acceptable_percent",
        module: "col",
        type: :integer,
        allowed: nil,
        default: 40,
        scope: :bank,
        description: "Minimum settlement offer as a percent of outstanding balance (e.g. 40 = can't offer to settle below 40% of what's owed)."
      }
    ]
  end
end
