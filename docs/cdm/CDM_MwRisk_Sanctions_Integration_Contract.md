# CDM ↔ mw_risk — Sanctions/AML Screening Integration Contract

**Status:** 📝 Draft for the mw_risk team to review/confirm. **Not implemented in
CDM yet — deliberately paused pending their sign-off**, per the module owner's
2026-07-11 direction: mw_risk has active development in progress on this exact
capability, so this document specifies what CDM needs rather than building
against a moving target.

**Why this exists:** `ApplicationScorer`'s moduledoc has claimed since before
this review that "all approvals go through AML/sanctions check via mw_risk
before finalising" — confirmed false during CDM-P1 (2026-07-11): no such call
exists anywhere in `score/1`. This document is the spec to close that gap
*correctly*, not just make the moduledoc's claim true.

---

## 1. What already exists today (verified 2026-07-11, `../mw-core/apps/mw_risk/`)

This is not a request to build something from nothing — the core primitive is
already there:

| Module | What it does | Scope today |
|---|---|---|
| `MwRisk.SanctionsCache.check/1` | O(1) exact-normalized-name lookup against an ETS table. Returns `{:hit, original_name, list_type}` or `:clear`. | **Global ETS table, not tenant-scoped** — see §3.1. |
| `MwRisk.SanctionsChecker.check_payload/1` | Extracts name-*like* fields from a **transaction-shaped** payload (`merchant_name`, `beneficiary_name`, `customer_name`, `sender_name`, etc.) and runs each through `SanctionsCache.check/1`. | Built for FAS transaction payloads, not applicant/KYC data — see §3.2. |
| `MwRisk.SanctionsChecker.fuzzy_check/1` | Jaro-Winkler fuzzy scan across the whole cache. | **Explicitly documented as UI-only ("for the manual tester UI, never from the hot path")** — the automated path is exact-match only. See §3.3. |
| `MwRisk.ScoringPipeline.do_score/1` (Step 0) | Calls `SanctionsChecker.check_payload/1` first; a hit is an immediate hard `:decline` (score `1.0`), skipping all other rule evaluation. | Already wired into `MwRisk.Pipeline.run/2`, which `VmuCore.FAS.RiskAdapter.evaluate/1` already calls for every FAS authorization. |
| `InfraRepo.Schemas.RiskSanction` (`risk_sanctions_list` table) | Has a `tenant_id` column. | **Not read by `SanctionsCache`** — see §3.1. |

So: sanctions screening by exact name match against a shared list already runs
on every card authorization today, via the existing FAS integration. CDM has
never called into any of this.

## 2. What CDM needs

`ApplicationScorer.score/1` (see `CDM_Gap_Implementation_Tracker.md` CDM-P1)
should screen the applicant **before** persisting an `APPROVED` decision —
declining or referring on a hit, never silently approving past it.

### 2.1 Input CDM can provide

From `VmuCore.CDM.ApplicationScorer.Application` + the joined `Customer`:
`first_name`, `last_name` (and `company_name` for corporate applicants —
`Customer` supports both individual and corporate KYC per CMS-G5), `date_of_birth`,
`nationality`, `id_type`/`id_number`, `sys_id`/`bank_id` (for tenant scoping,
if §3.1 is resolved).

### 2.2 Proposed call shape (negotiable — this is the point of this document)

```elixir
@spec screen_applicant(map()) ::
        {:ok, :clear}
        | {:ok, {:hit, %{matched_name: String.t(), list_type: String.t(), confidence: float()}}}
        | {:error, term()}

MwRisk.SanctionsChecker.screen_applicant(%{
  full_name: "Jane Q. Doe",
  date_of_birth: ~D[1985-03-12],
  nationality: "ARE",
  id_number: "784-1985-1234567-1",
  tenant_id: <int, per §3.1>
})
```

This is deliberately **not** a call to `check_payload/1` (that function's field
list is transaction-shaped — `customer_name` would technically match, but
piggybacking on it means CDM has to fabricate an empty transaction payload
around a single field, the same awkward pattern `FAS.RiskAdapter.warm_cache/0`
already has to use placeholder card/merchant data for an unrelated purpose).
A purpose-built applicant-screening entry point is cleaner for both sides and
is the natural place to add DOB/nationality-assisted disambiguation later
(reduces false-hit rate on common names — a known weakness of name-only
exact-match screening).

## 3. Open items for the mw_risk team to confirm

### 3.1 Tenant scoping

`risk_sanctions_list` has a `tenant_id` column, but `SanctionsCache`'s ETS
table has no tenant partitioning at all — every tenant's entries load into one
shared lookup space (`reload_from_db/0` loads *all* `active: true` rows,
`insert_entry/1` doesn't key on `tenant_id`). Two possibilities, please
confirm which:
- **Intentional** — sanctions lists (OFAC, UN, EU consolidated) are global by
  nature, so cross-tenant sharing is correct and `tenant_id` is unused/vestigial.
- **Gap** — different banks may subscribe to different list providers or
  jurisdiction-specific lists (this system already serves IN/EU/UAE markets
  per COL's config work), and per-tenant filtering is genuinely missing.

If it's a gap and it's what's currently in development, CDM's
`screen_applicant/1` call should pass `tenant_id` (same `sys_id`-derived
mapping `FAS.RiskAdapter.resolve_tenant_id/1` already uses, for consistency)
so it's ready the moment tenant scoping lands.

### 3.2 Fail-open vs. fail-closed on mw_risk unavailability — **the important one**

`FAS.RiskAdapter.evaluate/1` is deliberately fail-open: if mw_risk times out
(500ms budget) or raises, it returns a passthrough `:approve`. That's correct
for real-time card authorization — you cannot hold a swipe at the terminal for
a risk engine that's down, and the transaction is reversible/monitorable after
the fact.

**That pattern is wrong for credit-application sanctions screening.** An
application that gets `APPROVED` because the sanctions check timed out is a
credit line issued to a potentially-sanctioned applicant with no screening
ever having completed — a materially different, harder-to-reverse compliance
exposure than one delayed or misrouted transaction. CDM's integration should
**fail to a REFER/manual-review outcome**, not an auto-approve, when
`screen_applicant/1` can't complete. (CDM doesn't have a REFER status yet
either — see `CDM_Module_Requirements.md` §5 — so this also depends on that
being built; noting the dependency, not blocking this document on it.)

Please confirm this asymmetry is acceptable on the mw_risk side (i.e., that
`screen_applicant/1` can return a distinguishable `{:error, reason}` for
"couldn't complete" vs. `{:ok, {:hit, ...}}` for "screened, and it's a match" —
CDM needs to tell those two apart and route them differently, unlike FAS which
collapses both into the same passthrough).

### 3.3 Fuzzy/variant matching

Today's automated path (`check_payload/1` → `SanctionsCache.check/1`) is exact
normalized-string match only; `fuzzy_check/1` exists but is explicitly
UI-only/O(n)/never-hot-path. Name screening in most regulatory regimes expects
tolerance for transliteration, middle names, and minor variants. If this is
part of what's already in flight, no action needed from CDM's side beyond
waiting; if not, flagging it here so it's an explicit scope decision rather
than a silent gap once CDM starts relying on this path.

### 3.4 Audit trail

CDM will need to persist screening evidence per application (list
version/reference, matched-or-clear, timestamp) for the same reason
`decline_reason` was added in CDM-P1 — regulatory adverse-action /
audit-trail requirements (FR-CDM-009, FR-CDM-010). Please confirm what
`screen_applicant/1`'s response should carry to make that possible (a
reference id equivalent to `bureau_ref` would mirror the existing pattern in
`ApplicationScorer`).

---

## 4. What CDM will do once this is confirmed

Not before — tracked as a follow-up phase in `CDM_Gap_Implementation_Tracker.md`,
not started:

1. Add `sanctions_status`/`sanctions_reference`/`sanctions_screened_at` to
   `cdm_credit_applications` (mirroring how `decline_reason` was added in CDM-P1).
2. Call the agreed `screen_applicant/1` (or whatever it's finally named) from
   `ApplicationScorer.score/1`, before persisting an `APPROVED` decision.
3. Route a hit or an incomplete-screening result to REFER (pending that status
   existing) rather than silently declining or approving.
4. Live-verify against real data the same way every other phase in this
   project has been verified — not just confirm it compiles.
