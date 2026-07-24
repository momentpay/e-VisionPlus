# LMS — Gap Implementation Tracker

> Source: `LMS_Module_Requirements.md` gap analysis, reconciled 2026-07-11.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`

---

## Re-port note (2026-07-24)

LMS-P1 below (verified 2026-07-11) was never committed to standalone
vmu_core's git history — the same "M2: extract vmu_lms into Avenza
umbrella" commit that lost COL's P1-P9 build (see
`docs/col/COL_Gap_Implementation_Tracker.md`'s own re-port note) also
carried LMS's newer work off into `Avenza/apps/vmu_lms` without it ever
coming back. Unlike COL, no files were entirely missing here — 10 of 17
`lib/vmu_core/lms/` files had simply diverged (Avenza's were newer); the
other 7 were untouched since the original build and identical.

This was a **real, live bug**, not just a missing feature: the
committed `RedemptionProcessor.redeem/3` unconditionally zeroed
`open_to_redeem` after every redemption with a comment claiming "recalculated
nightly" (no such job existed) — any account that redeemed once was
permanently locked out of redeeming again, no matter how many points it
earned afterward. `PointsExpiryJob` had the same class of bug in reverse
(expired points never released from `open_to_redeem`, staying falsely
"redeemable" forever). Confirmed with the user before porting — chose to
bring in all 10 diverged files (4 with real logic changes: `points_engine.ex`,
`points_ledger.ex`, `redemption_processor.ex`, `oban/points_expiry_job.ex`;
6 were pure `Application.compile_env` indirection style differences, harmless
either way) rather than hand-reapplying just the bug fix in isolation.

New test coverage: `test/vmu_core/lms/points_redemption_bugfix_test.exs`
(5 tests, real Scheme→Group→Plan→RateTier→Enrollment chain, real CMS
account fixture — not the separately-broken, unrelated
`points_lifecycle_test.exs`, which uses a stale `entry_type` field name
that never matched this schema in either copy and predates the M2 split).
Full CMS/FAS/COL/admin regression before and after: same 10 pre-existing
failures, zero regressions.

## LMS-P2 — Warehouse-Release Job + Reversal/Chargeback Clawback (FR-LMS-012) ✅ (2026-07-24)

The two items LMS-P1 explicitly flagged as still open, plus one more real
bug found while building the second one. Neither exists in Avenza's copy
either — genuinely new work, not a re-port.

**Foundational bug found before it could ship, not after:**
`lms_points_ledger.source_clearing_id` was created `:bigint` in the
original 2026-06-14 LMS migration, before `trams_clearing_records`'
real `uuid` primary key (`clearing_id`) was finalized (2026-07-03) —
never reconciled afterward. `PointsEngine.post_earned_points/7` has
always passed a real `ClearingRecord.clearing_id` (uuid) into this
column, which fails every real Ecto cast. 0 rows had this column
populated in dev, confirming the real earn pipeline
(`PointsCalculationJob` → `PointsEngine.process_transaction/2`) has
never actually succeeded against real clearing data in either copy of
this codebase. Fixed via a type-change migration (bigint → uuid); no
data to migrate.

Also found: `PointsExpiryJob` (LMS-P1) was never actually scheduled
anywhere despite its own moduledoc claiming "runs on the 1st of each
month" — fixed alongside the new job, same class of gap.

| # | Task | File(s) | Status |
|---|---|---|---|
| P2.1 | `lms_points_ledger.source_clearing_id` bigint → uuid fix | migration `20260724120001_...`, `lib/vmu_core/lms/points_ledger.ex` | ✅ |
| P2.2 | `VmuCore.LMS.Oban.WarehouseReleaseJob` — daily, promotes `WAREHOUSE`-state entries to `ACTIVE` once the owning scheme's `warehouse_days` has elapsed since posting, incrementing `open_to_redeem` by the released amount (`points_balance`/`lifetime_earned` were already correct at earn time — only `open_to_redeem` was withheld) | `lib/vmu_core/lms/oban/warehouse_release_job.ex` | ✅ |
| P2.3 | `VmuCore.LMS.Clawback.claw_back_transaction/1` (FR-LMS-012) — given a `TRAMS.Transaction` id, finds every `ClearingRecord` matched to it, then every still-`ACTIVE` `PointsLedger` entry earned from those, and reverses each (moves to `HISTORY`, posts a negative `CLAWBACK` ledger entry, decrements `points_balance`/`open_to_redeem`). Honestly scoped: already-redeemed/expired entries are NOT clawed back (the cardholder already received their value) — the return value reports `already_spent` separately so this isn't silently swallowed | `lib/vmu_core/lms/clawback.ex` | ✅ |
| P2.4 | Hooked into `DPS.Dispute.transition/2` on the transition to `CLOSED_WIN` only — that status means the cardholder never actually paid for the disputed purchase (scheme reimburses, no customer-balance impact per `Dispute`'s own moduledoc); `CLOSED_LOSE`/`CANCELLED` re-debit the cardholder, who keeps the points. Fail-safe: LMS being unreachable never blocks dispute resolution, same posture as this file's existing network-filing call | `lib/vmu_core/dps/dispute.ex` | ✅ |
| P2.5 | Both jobs added to the Oban crontab (`WarehouseReleaseJob` daily 23:45, after the 23:30 earn run; `PointsExpiryJob` monthly, 1st at 01:00 — the schedule its own moduledoc always claimed but never had) | `config/config.exs` | ✅ |

**Explicit scope decision**: the auth-level `authorization_reversed` TRAM
event (MTI 0400, before clearing) was considered and NOT hooked — points
aren't earned until a clearing record reaches `MATCHED`, so an auth
reversal before that point has nothing to claw back yet. Only the
post-settlement chargeback-win path is a real clawback trigger.

7/7 tests: `clawback_test.exs` (4 — a real end-to-end earn through a
genuine `ClearingRecord` + `Clawback.claw_back_transaction/1` proving the
`source_clearing_id` fix works, a clean no-op for a transaction that
never earned points, an already-redeemed entry correctly reported as
`already_spent` rather than clawed back, and the real
`DPS.Dispute.transition/2` → `CLOSED_WIN` hook); `warehouse_release_job_test.exs`
(3 — releases once elapsed, does not release early, an immediate-earn
scheme is untouched). Full CMS/FAS/COL/DPS/admin regression before and
after: same 10 pre-existing failures, zero regressions.

---

## LMS-P1 — `open_to_redeem` Correctness Fix ✅ (2026-07-11)

The 2026-07-11 documentation reconciliation pass surfaced a serious bug, not
just a gap: `RedemptionProcessor.redeem/3` unconditionally zeroed
`open_to_redeem` after every redemption with a comment claiming "recalculated
nightly" — no such job existed anywhere in the codebase. Net effect: the
first redemption (manual or auto-disbursement) on any account permanently
locked it out of redeeming again, regardless of how many points it
subsequently earned. Deeper investigation found the field was in fact never
correctly maintained at all — earn never incremented it and expiry never
decremented it, so `open_to_redeem` only ever reflected whatever a
migration/seed script happened to set at account creation (typically 0).

| # | Fix | File(s) |
|---|---|---|
| P1.1 | `PointsLedger.active_balance/1` — new: sum of ACTIVE-state ledger entries for an account. Correct because `RedemptionProcessor`'s FIFO deduction already mutates each ACTIVE row's `points_amount` down to its remaining balance, so summing ACTIVE rows *is* the authoritative redeemable balance, no separate running total needed. | `lms/points_ledger.ex` |
| P1.2 | `PointsEngine.update_account_balance/3` — now also increments `open_to_redeem` on earn, but **only when `warehouse_state == "ACTIVE"`** (immediate-earn schemes, `warehouse_days == 0`, the common case). Points posted as `WAREHOUSE` correctly do NOT increment it yet — see the known limitation below. | `lms/points_engine.ex` |
| P1.3 | `RedemptionProcessor.update_account_redeemed/2` — replaced the unconditional zero with `PointsLedger.active_balance/1`, recomputed post-deduction in the same transaction. | `lms/redemption_processor.ex` |
| P1.4 | `PointsExpiryJob.expire_entry/2` — now also decrements `open_to_redeem` by the expired amount (previously only `points_balance` was touched, so expired points stayed "redeemable" forever). | `lms/oban/points_expiry_job.ex` |

**Verification (2026-07-11):** live smoke test against real Postgres (real
scheme/group/plan/rate-tier chain, real `PointsEngine`/`RedemptionProcessor`
calls, no mocking): earned 100+100 points → `points_balance=200,
open_to_redeem=200` (previously untested — earn never touched this field at
all); redeemed 80 → `open_to_redeem=120` correctly recomputed; **redeemed 50
again → succeeded with `open_to_redeem=70`** (this is the exact scenario that
was broken — a second redemption after a first one; previously always
rejected with `insufficient_open_to_redeem` regardless of real balance);
over-redemption of 999 correctly still rejected. All test data cleaned up,
dev DB confirmed clean of residue after.

**Known limitation, not fixed here (separate, larger gap):** no job promotes
`WAREHOUSE`-state ledger entries to `ACTIVE`. For any scheme configured with
`warehouse_days > 0`, earned points are posted as `WAREHOUSE` and — per P1.2's
scoping — never increment `open_to_redeem`, meaning they also never become
redeemable, ever. This is a distinct missing feature (a warehouse-release
job), not part of this bug fix; flagging so it isn't mistaken for closed.
Every scheme observed in this codebase so far defaults `warehouse_days: 0`,
so this doesn't affect the common path, but would need addressing before any
scheme actually uses warehousing.

**Not addressed in this phase** (see `LMS_Module_Requirements.md` §5 for the
full list): reversal/chargeback clawback (FR-012), MCC-based earn exclusions
(FR-005), time-based accelerators (FR-004's calendar half), expiry
pre-notification (FR-019b), breakage estimation (FR-021), statement feed
(FR-023), ops UI, and the warehouse-release job noted above.
