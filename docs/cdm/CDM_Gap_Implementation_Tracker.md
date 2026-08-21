# CDM — Gap Implementation Tracker

> Source: `CDM_Module_Requirements.md` gap analysis. Statuses: `✅ Done` ·
> `🔄 In Progress` · `⬜ Pending`
> Last updated: 2026-07-11

---

## CDM-P1 — Decision-Persistence Bug Fixes ✅ (2026-07-11)

Before any new CDM feature work, live verification against a real Postgres
connection (not just reading the code) surfaced that `ApplicationScorer.score/1`
— the module's single most important function — had **never actually worked**.
Two separate bugs, both in the persistence path, not the scoring logic itself.

| # | Bug | Fix |
|---|---|---|
| B1 | `score/1`'s `with` chain routed `LimitAllocator.calculate/6`'s business-outcome errors (`{:error, :tier_declined}` for every plain low-score decline, `{:error, :dsr_cap_exceeded}` for the DSR cap) through the same short-circuit path as *system* failures (bureau adapter down, record not found). Every declined application returned a bare `{:error, reason}` **before `persist_decision/2` ever ran** — the application stayed `status: "PENDING"` forever, and no decline was ever recorded. Both are common, expected outcomes (some applications *should* decline), not exceptional system failures. | Restructured `score/1` to always resolve a `decision` map (via new `build_decision/3`) and always call `persist_decision/2`, whether the tier/DSR result is an approval or a decline. `{:error, reason}` is now reserved for genuine system failures only. Added `decline_reason` ("LOW_BUREAU_SCORE" / "DSR_CAP_EXCEEDED") to the decision and persisted it — the schema already had an unused `decline_reason` column. |
| B2 | `persist_decision/2` queried the **raw table name string** `"cdm_credit_applications"` in its `from`, not the schema module. With no schema, Ecto has no type metadata for `application_id` (`:binary_id`), so it sent the hyphenated 36-character UUID string straight to Postgrex instead of dumping it to a 16-byte binary first — Postgrex's `:uuid` encoder rejected it outright (`DBConnection.EncodeError`) on *every single call*, approve or decline. This is why B1 went unnoticed for the approval path too: nothing had ever exercised `persist_decision/2` against a real Postgres connection before this session. | Changed the query source from the table-name string to `__MODULE__.Application` (the schema already defined in the same file), giving Ecto the type info it needs to dump the UUID correctly. |

**Verification (2026-07-11):** `mix compile --force` clean, no new warnings. Live
script against the real dev DB, three real applications scored via the actual
`MockBureauAdapter` (deterministic per `id_number`, no mocking of the function
under test):
- An application landing in the PRIME bracket (score ≥ 720) → `{:ok, decision}`
  with `status: :approved`, real `approved_limit` computed by `LimitAllocator`;
  reloaded the row from Postgres and confirmed `status: "APPROVED"`,
  `decline_reason: nil`.
- An application landing below 500 → confirmed **for the first time ever**
  that a decline actually persists: reloaded row showed `status: "DECLINED"`,
  `decline_reason: "LOW_BUREAU_SCORE"` (previously: silently stuck at
  `"PENDING"` forever).
- An application with a PRIME-bracket score but `existing_monthly_payments`
  engineered to blow the 50% DSR cap → reloaded row showed `status:
  "DECLINED"`, `decline_reason: "DSR_CAP_EXCEEDED"`.

Test data cleaned up after (dev DB confirmed clean).

**Not addressed in this phase** (documented, not silently dropped — see
`CDM_Module_Requirements.md` §5/§6 for the full list): the moduledoc's claim
that "all approvals go through AML/sanctions check via mw_risk before
finalising" has no corresponding call anywhere in `score/1` — a real gap
between documented and actual behavior. **Closed by CDM-P2 (2026-07-23)
below** — also found live, while closing it, that this phase's own claimed
B1/B2 persistence fixes were not actually present in the code and had to be
re-applied. Also still open: policy knockout rules
beyond bureau score (age/income floor/blacklist), a REFER/manual-override
queue, `CustomerExposure.headroom/2` (built by CMS-G5.1 specifically as CDM's
FR-016 entry point) is not yet consumed anywhere in CDM, and the auto
limit-increase program applies silently with no customer offer/acceptance
step (ties to an unanswered open question about per-market opt-in
requirements).

## CDM-P2 — AML/Sanctions Screening ✅ Done (2026-07-23)

**Unblocked**: `mw_risk` (`../mw-core/apps/mw_risk`) evolved past the contract's
2026-07-11 snapshot — `SanctionsChecker.check_payload/2` now takes an explicit
`sanction_configs` list (`%{multipart_data_field:, distance:}`) instead of only
its transaction-shaped fallback field list, and its matching moved from plain
exact-string lookup to an **indexed Levenshtein multipart fuzzy match** (see
`SanctionsCache.match_multipart/2`). That arity is generic enough that the
purpose-built `screen_applicant/1` the contract proposed was never needed —
`check_payload/2` with an applicant-shaped payload/config already does the job.
No mw_risk-side changes were required; the `screen_applicant/1` ask in the
contract is superseded, not fulfilled literally.

**Built:**
1. Migration `20260723000001` — `sanctions_status` / `sanctions_reference` /
   `sanctions_screened_at` on `cdm_credit_applications` (per the contract §4.1
   ask).
2. `VmuCore.CDM.SanctionsScreening` (new) — calls `MwRisk.SanctionsChecker.
   check_payload/2` directly (real path dep, same-umbrella call, same pattern
   as `VmuCore.FAS.RiskAdapter`), screening both `full_name` and
   `company_name` (corporate applicants) as separate configs, distance 2
   (matches `check_payload`'s own default). **Fail-CLOSED** — the opposite of
   `RiskAdapter`'s fail-open posture, per contract §3.2: `Task.yield`/
   `Task.shutdown` on a 500ms budget; any timeout or raised exception returns
   `:error`, never a silent pass.
3. `ApplicationScorer.score/1` now always screens before persisting: a
   confirmed hit overrides the tier/DSR outcome to **DECLINED** /
   `decline_reason: "SANCTIONS_HIT"` regardless of how well the applicant
   otherwise scored (mirrors the FAS gateway's own "sanction always declines"
   rule — confirmed against the real `mw-core/config/gateway-rule-tests/
   gw-02-BypassSanctionsExactMatch.json` /`gw-03-BypassOfacFuzzy.json`
   fixtures, which assert exactly this for the transaction path); an
   incomplete screen overrides to **REFERRED** / `"SANCTIONS_SCREENING_
   UNAVAILABLE"` (fail-closed, never APPROVED).

**2 real bugs found and fixed live, in code this phase had to touch anyway**
(neither is the sanctions feature itself — both are pre-existing defects in
`score/1`'s persistence path that CDM-P1's tracker entry claimed were already
fixed, but were not actually present in the code when checked 2026-07-23):
- `persist_decision/2` queried the **raw table-name string**
  `"cdm_credit_applications"`, not the schema module — the exact B2 bug
  CDM-P1 described (Ecto has no `:binary_id` type info without the schema,
  so the UUID never dumps correctly). Fixed to `__MODULE__.Application`.
- The tier/DSR `with`-chain still short-circuited a decline through
  `LimitAllocator.calculate/6`'s `{:error, :tier_declined}` /
  `{:error, :dsr_cap_exceeded}` results — the exact B1 bug — meaning a
  declined application never reached `persist_decision/2` and stayed
  `"PENDING"` forever. Restructured into `build_decision/4` (always resolves
  a decision map for both outcomes) + `apply_sanctions_screening/2` (applies
  on top), so every path — approve, tier-decline, DSR-decline, sanctions hit,
  screening-unavailable — reaches `persist_decision/2`.
- Also found live: `NaiveDateTime.utc_now()` written directly into this
  schema's `:naive_datetime` (non-usec) fields raises `ArgumentError` at
  Ecto dump time (fractional seconds not allowed). Affected `decided_at`
  (pre-existing) and the new `sanctions_screened_at`; centralized a
  `now/0` helper that truncates to `:second`.

**Verification (2026-07-23), live script, real Postgres, no mocking** —
`MwRisk.SanctionsCache.load/1` (the same real API `SanctionsLive` uses after
an admin writes a new entry) used to load real entries, not a stub:
- CLEAR: real applicant, empty cache (this dev DB has no `risk_sanctions_list`
  table — see note below) → `APPROVED`, `sanctions_status: "CLEAR"`.
- Exact HIT: loaded `"Vladimir Petrov Sanctioned"` (ofac), applicant on
  $50k/month income (would otherwise land PRIME-approved) → `DECLINED`,
  `decline_reason: "SANCTIONS_HIT"`, `sanctions_reference: "Vladimir Petrov
  Sanctioned (ofac)"`.
- Fuzzy HIT: applicant named `"Vladamir Petrof Sanctioned"` (2-character
  misspelling) against the same loaded entry → also correctly declined,
  proving the indexed Levenshtein distance-2 match works for applicant
  screening, not just the transaction path.
- Corporate HIT: loaded `"Bank Melli Iran"` (ofac); applicant's own personal
  name clean, `company_name: "Bank Melli Iran"` → correctly declined on the
  company-name config, proving both identity fields are screened
  independently.
- Decline persistence (the B1 fix): all three hit cases above persisted
  `DECLINED` correctly (previously would have stayed `PENDING` forever).
- Fail-closed timeout mechanism verified directly (`Task.async` + 700ms sleep
  vs. the wrapper's 500ms budget → `:error`), proving the exact
  `Task.yield`/`Task.shutdown` pattern `SanctionsScreening.screen/1` uses
  correctly resolves to `:error` under a real timeout.

All test data (5 customers, 5 applications) deleted after; `SanctionsCache`
reset to empty (`load([])`) so no test entries were left in the shared ETS
cache. Dev DB confirmed clean.

**Update (2026-07-23, same day): the "infra tables are absent" premise above
was wrong, and the real root cause was worse than a missing table.**
`InfraRepo.Repo` is hardcoded `adapter: Ecto.Adapters.MyXQL` in mw-core's own
`apps/infra_repo/lib/infra_repo/repo.ex` — it always speaks MySQL, never
Postgres. `vmu_core`'s `config/config.exs` had it pointed at `vmu_core_dev`
on port 5432 with Postgres credentials — a MySQL client aimed at a
Postgres-speaking port, which could never connect, not just here but for
every mw_risk consumer in this repo (the FAS gateway's own `RuleCache`/
`SuppressionsCache` were silently degrading the same way, confirmed via the
same boot-log `MyXQL.Client ... timed out because it was handshaking` /
`socket closed` errors visible in every prior session in this repo). Fixed:
`config.exs` now points `InfraRepo.Repo` at mw-core's real MySQL dev
database (`mw_core_dev`, `root`/no password, `localhost:3306`) — confirmed
live: 79,373 real active sanctions rows, `SanctionsCache` fully loads 76,046
of them (`:set`-keyed by normalized name, so exact-duplicate names collapse)
in ~8s on a cold boot.

**Second real bug found closing this out**: `check_payload/2` against the
full real 76k-entry list takes **~1.3–1.6s** (measured live, indexed
Levenshtein multipart scan) — `SanctionsScreening`'s `@timeout_ms` had been
set to `500`, copied from `FAS.RiskAdapter`'s card-authorization budget
without checking whether it fit CDM's very different context. Every real
call timed out, and the fail-closed design did exactly what it was built to
do — routed every application to `REFERRED` rather than silently approving
— but that's not usable in practice if *every* application ends up in manual
review. Fixed: raised to `5_000ms` (~3x measured latency headroom), justified
in the module doc by CDM having no card-present latency SLA the way FAS
does.

**Re-verified live against the real 76k-entry list after both fixes** (not
synthetic `SanctionsCache.load/1` injection this time — genuine
`reload_from_db/0` data): an applicant named `"Vladimir Petrov"` correctly
matched a real EU-list entry, `"Vladimir Sergeevich PETROV"`, via multipart
fuzzy matching (first/last name parts matched independently despite the
real entry having a middle name and different casing) → `DECLINED`,
`sanctions_reference: "Vladimir Sergeevich PETROV (eu)"`; a corporate
applicant with `company_name: "Bank Melli Iran"` matched the real entry
of the same name → `DECLINED`; an ordinary unrelated name
(`"Priyanka Shanmugam"`) correctly screened `CLEAR` against the full real
list — no false positive found. (That third application still persisted as
`DECLINED` overall, but for an unrelated, correct reason — `MockBureauAdapter`
scored it below the tier-decline threshold; `sanctions_status: "CLEAR"`
proves the sanctions screen didn't cause that outcome and isn't
silently overridden by it either.)

**Residual limitation, not fixed here (honest gap, not silently dropped):**
if the sanctions cache is ever genuinely empty (never loaded / DB truly
unreachable for a *different* reason than what was just fixed),
`check_payload/2`'s own `SanctionsCache.size() == 0 -> :clear` early exit
still makes that indistinguishable from "screened, nothing found" at the
mw_risk layer — the fail-closed wrapper here only catches a `Task` timeout
or a raised exception, not a silently-empty cache. Worth a monitoring alert
on `SanctionsCache.size()` staying at 0 past its expected boot-load window,
not a code fix in CDM.

**Not addressed in this phase (still open, per the contract's other items):**
tenant scoping (§3.1 — `SanctionsCache` still has no per-tenant partitioning,
unresolved question unchanged); a REFER/manual-review **queue/UI** (the
`REFERRED` status now gets set and persisted correctly, but there is still no
screen to work a REFERRED application — same class of gap as DPS's missing
P5 ops UI); audit-trail retention policy for `sanctions_reference` beyond the
raw matched-name+list-type string currently stored.
