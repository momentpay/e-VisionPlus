# CMS — Gap Implementation Tracker

> Source: `CMS_Module_Requirements.md` gap analysis + reviewed Open-Question
> answers (2026-07-04). Phases use the `CMS-G1`..`CMS-G5` prefix (distinct from
> the historical `../CMS_Implementation_Tracker.md` and `../phase-tracker.md`).
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`
> Last updated: 2026-07-04

---

## Decisions from the Q&A review (2026-07-04)

### ADR-C1: Configuration via ParameterEngine, not YAML files
The reviewed answers specify market/product-configurable parameters with
YAML examples. **Platform adaptation:** this codebase's idiom for exactly that
cascade is the SYS → BANK → LOGO → BLOCK ParameterEngine (ETS-cached,
hot-refreshable, admin-UI editable) — new parameters land there instead of
config files. Market-level values → BANK columns; product-level →
LOGO columns. Intent honored, mechanism native.

| Answered parameter | Level | Column | Default |
|---|---|---|---|
| `repayment_hierarchy_order` | LOGO (product) | `logo_parameters.repayment_hierarchy_order` (CSV of bucket names) | nil → scheme-default hierarchy |
| `penalty_apr_cure_rule` | LOGO | `logo_parameters.penalty_apr_cure_rule` | `"arrears_cleared_immediately"` |
| `payment_channels_enabled` | BANK (market) | `bank_parameters.payment_channels_enabled` (CSV) | `"gateway,direct_debit"` (v1 scope per answer) |
| `credit_reporting_format` | BANK | `bank_parameters.credit_reporting_format` | `"Metro2"` (per-market: CIBIL_local, AlEtihad_local) |

### ADR-C2: Penalty APR persistence + cure
Current behavior drops penalty APR the moment DPD < trigger. Per the reviewed
cure rules, penalty APR must **persist until cured**. Two rule grammars
supported: `arrears_cleared_immediately` and
`arrears_cleared_and_<N>_cycles_current`. Requires account-level state
(`penalty_apr_active`, `penalty_cure_cycles`); activation happens in the
accrual job, cure evaluation once per cycle in the statement job.

### ADR-C3: v1 payment channels = gateway + direct_debit
`PaymentIntake` validates the channel against the BANK parameter before
distribution. v2 channels (mobile_wallet, branch_cash) are a config change,
not a code change.

### ADR-C4: Single billing currency per account — confirmed
No dual-currency statements. Multi-currency remains transaction-side only
(FX conversion at posting, FR-042 — already built).

### ADR-C5: Bureau format routed per BANK
`BureauFormatRouter` dispatches on `credit_reporting_format`: Metro2 →
existing `Metro2Generator`; `CIBIL_local` / `AlEtihad_local` → explicit
`{:error, {:format_not_implemented, fmt}}` stubs until those specs are sourced.

---

## Bugs found during this review cycle

| # | Bug | Status |
|---|---|---|
| B1 | `cdm/behavioral_rescorer.ex` aliased `AccountStateCoordinator` under `VmuCore.Shared.*` (lives in `VmuCore.CMS.*`) — suspend/upgrade/downgrade actions crashed at runtime | ✅ Fixed 2026-07-04 |
| B2 | `RepaymentDistributor.build_plan_hierarchy/1` ignored its `account_id` argument and loaded **all** active `PlanSegment` rows across every product — payment priority could follow another LOGO's plans | ✅ Fixed in CMS-G1 (filter by account's sys/bank/logo) |
| B3 | `InternalGlPoster.post/1` duplicate detection checked `entry_id: nil`, but `LedgerEntry`'s PK is a **client-generated** binary_id — the struct always carries an id, so ON-CONFLICT-skipped inserts returned `{:ok, phantom_entry}` instead of `{:error, :duplicate}`. DB stayed correct (unique index held); every caller trusting the return contract (DPS provisional credit, adjustments, refunds) was misinformed. Fixed with an insert-then-read-back id comparison | ✅ Fixed 2026-07-05 (found by the G4 duplicate-refund guard test) |

---

## CMS-G1 — Config Foundation (the four answered parameters) 

| # | Task | File(s) | Status | Completed |
|---|---|---|---|---|
| G1.1 | Migration — LOGO: `repayment_hierarchy_order`, `penalty_apr_cure_rule`; BANK: `payment_channels_enabled`, `credit_reporting_format`; ACCOUNT: `penalty_apr_active`, `penalty_cure_cycles` | migration `20260704000001` | ✅ Done | 2026-07-04 |
| G1.2 | Schemas + ParameterEngine load for the four new parameters | `logo_parameter.ex` · `bank_parameter.ex` · `account.ex` · `parameter_engine.ex` | ✅ Done | 2026-07-04 |
| G1.3 | `RepaymentDistributor.distribute_configured/3` — reads `repayment_hierarchy_order` (LOGO cascade), parses/validates CSV bucket names, falls back to scheme default; fix B2 (plan query filtered to account's logo) | `repayment_distributor.ex` | ✅ Done | 2026-07-04 |
| G1.4 | `PenaltyAprManager` — activation (accrual detects DPD ≥ trigger → `penalty_apr_active`), persistence (accrual honors flag regardless of current DPD), cure evaluation at statement cycle per rule grammar | `cms/penalty_apr_manager.ex` (NEW) · `eod/accrue_interest_job.ex` · `eod/generate_statement_job.ex` | ✅ Done | 2026-07-04 |
| G1.5 | `PaymentIntake` — channel validation against `payment_channels_enabled`, idempotent (`"payment:<reference>"` ledger key), configured-hierarchy distribution, bucket persistence, PAYMENT GL entry, OTB restore | `cms/payment_intake.ex` (NEW) | ✅ Done | 2026-07-04 |
| G1.6 | `BureauFormatRouter` — per-BANK format dispatch (ADR-C5) | `cms/bureau_format_router.ex` (NEW) | ✅ Done | 2026-07-04 |

## CMS-G2 — Payments Completion ✅ (2026-07-04)

**Foundation:** `cms_payments` register (migration `20260704000004`) — one row
per payment with the exact bucket-level `postings` breakdown persisted at
intake, enabling exact reversal instead of reverse-hierarchy guessing;
`PaymentIntake` idempotency now consults the register first.

| # | Task | Status |
|---|---|---|
| G2.1 | `PaymentReversal.reverse/2` — exact re-debit from stored postings; GL REVERSAL `"payment_reversal:<ref>"` (DR 1001/CR 9001, mirror of PAYMENT); LOGO `returned_payment_fee` assessed as FEE entry + `unpaid_fees` when configured > 0; OTB re-debited (negative `credit_open_to_buy` — plain Decimal.add verified); register → REVERSED; double-reversal rejected. *Delinquency re-ages at next EOD from restored balances; same-day synchronous re-age is a flagged refinement* | ✅ `cms/payment_reversal.ex` · `cms/payment.ex` |
| G2.2 | Autopay — `cms_autopay_mandates` (one ACTIVE per account via partial unique index); MIN_DUE / FULL / FIXED (FIXED capped at statement balance); due = statement `balance_date` + `payment_due_days` (LOGO param, default 21); collected via `direct_debit` with reference `"autopay:<account>:<due_date>"` → idempotent per cycle by construction; daily cron 06:00 | ✅ `cms/autopay.ex` · `cms/autopay_mandate.ex` · `cms/oban/autopay_run_job.ex` · `config/config.exs` |
| G2.3 | Suspense — `receive_unmatched/1` parks unidentifiable receipts (no GL, no bucket movement — funds stay in clearing); direct application of a suspense reference is blocked (`:reference_in_suspense`); `apply_suspense/2` runs the normal distribution/GL/OTB path preserving the original reference; `suspense_queue/1` for ops | ✅ `cms/payment_intake.ex` |

**Verification (2026-07-04):** smoke-tested 10/10 against `vmu_core_dev` —
register row with postings breakdown (fees 20 + cash 40 for a 60 payment);
reversal restored the exact pre-payment buckets with REVERSAL GL 1001/9001;
double-reversal rejected; suspense parked + direct-apply blocked + ops apply →
POSTED with ledger entry; MIN_DUE autopay collected 17.00 via direct_debit on
the derived due date; job re-run idempotent (1 row); re-enroll replaced the
active mandate. Originals restored after test.

## CMS-G3 — Account Lifecycle ✅ (2026-07-05)

**Foundation:** migration `20260704000005` adds `closure_requested_at` +
`dormant_since` to `cms_accounts`; 7 new `NonMonetaryEvent` types
(closure_requested/cancelled, account_closed/reopened, product_transfer,
dormancy_flagged/cleared).

| # | Task | Status |
|---|---|---|
| G3.1 | `AccountClosure` — request → immediate close when clean, else BLOCKED + pending; close preconditions enforced: zero balance AND no active pending holds AND **no open DPS dispute**; close zeroes OTB, notifies ASC, cancels autopay, stamps `close_date`; `cancel_closure/2`; `reopen/2` within `:cms_reopen_window_days` (default 30); `finalize_pending/0` retried nightly by the sweep | ✅ `cms/account_closure.ex` |
| G3.2 | `AccountTransfer` — LOGO→LOGO within same SYS/BANK; target LOGO + BLOCK existence validated; balances stay (pricing re-derives from the new cascade at next accrual); credit limit **clamped to new LOGO `credit_limit_max`** with ASC refresh + clamp recorded in the event payload; same-product and unknown-target rejected | ✅ `cms/account_transfer.ex` |
| G3.3 | Dormancy — nightly sweep flags ACTIVE accounts with no ledger posting, no authorization, and no payment within `:cms_dormancy_days` (default 365; `open_date` also aged so new accounts never flag); recent activity clears the flag; both directions event-logged as SYSTEM. Inactivity **fee** deliberately deferred until an `inactivity_fee` LOGO parameter is defined (G4 candidate) | ✅ `cms/oban/account_lifecycle_sweep_job.ex` (cron 05:00, before 06:00 autopay) |

**Verification (2026-07-05):** main test 10/11 + dormancy-only test 3/3 against
`vmu_core_dev` — dirty closure parks BLOCKED, duplicate request rejected, sweep
keeps it blocked while balance outstanding, closes when zeroed (CLOSED /
close_date / OTB 0), reopen within window, 60-day-old closure rejected against
the 30-day window; transfer clamped 5000→1000 at the temp LOGO's max and
rejected same-product/unknown-logo; dormancy flag + SYSTEM event + clear on new
payment. **Bonus validation from the first run:** the test initially picked an
account with a live CHARGEBACK_FILED dispute — closure correctly refused,
proving the dispute blocker against real data. (Note: that run also exposed
that smoke tests must select dispute/hold-free candidates; the balance-bucket
values of the first candidate account were test-mutated and could not be
restored — dev-only data.)

## CMS-G4 — Financial Edge Cases ✅ (2026-07-05)

| # | Task | Status |
|---|---|---|
| G4.1 | Credit-balance refund — credit balance defined as Σ POSTED payment `remainder` − Σ refunds (buckets never go negative by design; REVERSED payments drop out automatically); `refund/3` enforces operator ≠ supervisor + amount ≤ available; GL ADJUSTMENT DR 1001/CR 9001 keyed `"refund:<account>:<reference>"`; no bucket/OTB movement (credit never entered either); `refund_candidates/1` ops queue | ✅ `cms/credit_balance_refund.ex` |
| G4.2 | Promo expiry — the *pricing* revert was already dynamic (`PlanSegment.effective_apr/1`); added the missing cleanup pass to the nightly lifecycle sweep: expired promos get `promo_apr`/`promo_expiry_date` nulled with a from→to APR log so parameter screens can't show a dead promo as live | ✅ `cms/oban/account_lifecycle_sweep_job.ex` (pass 4) |
| G4.3 | Charge-off recovery — `ChargeOffRecovery.record_recovery/3` validates WRITTEN_OFF and wraps COL's existing `post_recovery/3` (DR 1000/CR 6001, `"RECOVERY-<ref>"`); `total_recovered/1`; **`PaymentIntake` now routes WRITTEN_OFF accounts to recovery** — previously a payment would have distributed into written-off buckets and credited OTB (real gap closed); interest/fee suppression confirmed structural (EOD selects only ACTIVE/DELINQUENT) | ✅ `cms/charge_off_recovery.ex` · `cms/payment_intake.ex` |

**Verification (2026-07-05):** smoke-tested 9/9 against `vmu_core_dev` — 100
payment against 30 owed left remainder 70 = credit balance; refund guards
(same-operator, over-balance, duplicate reference, residual cap) all held;
refund 50 posted 1001/9001 leaving 20; expired promo nulled with APR reverting
to 24.00; recovery 40 posted 1000/6001; duplicate recovery rejected; a normal
gateway payment to the WRITTEN_OFF account routed to recovery with buckets
untouched and no register row; recovery on an ACTIVE account rejected.
Found+fixed bug B3 (`InternalGlPoster` phantom-duplicate returns) during
verification.

## CMS-G5 — Cross-Module ✅ (2026-07-05)

**Review decision (2026-07-05):** local bureau formats built from publicly
available web documentation, with every field layout **config-overridable**
(`:bureau_format_overrides`) so corrections from official member specs are a
config change, not a deployment (ADR-C6).

| # | Task | Status |
|---|---|---|
| G5.1 | `CustomerExposure.exposure/1` — per-customer roll-up: total limit / outstanding (bucket-derived, same source EOD uses) / OTB / worst DPD across countable statuses; WRITTEN_OFF principal reported separately as `written_off_exposure`; `headroom/2` is CDM FR-016's entry point (never negative) | ✅ `cms/customer_exposure.ex` |
| G5.2 | Configurable bureau formats — `Bureau.ReportingData` (row collection + `{:customer, f}`/`{:account, f}`/`{:bucket, f}`/`{:computed, x}` resolution mini-language; masked account refs, never raw PAN); `Bureau.FormatSpec` (defaults deep-merged with `:bureau_format_overrides`, per-segment replacement); **CIBIL TUDF** generator (fixed TUDF header + PN/ID/PT/PA/TL tag-length-value subjects + ES + TRLR, per the publicly documented TUDF/UCRF structure — ⚠ field layouts are a structured draft pending validation against the member's official UCRF guide); **AECB** generator (delimited H/D/T skeleton — no public spec exists, entire column set is config); router dispatches both | ✅ `cms/bureau/reporting_data.ex` · `format_spec.ex` · `cibil_tudf_generator.ex` · `aecb_generator.ex` · `bureau_format_router.ex` |

**Verification (2026-07-05):** smoke-tested 8/8 (read-only — no data mutated) —
exposure totals match a manual SQL sum with headroom capped at zero; TUDF
render produced header `TUDF12…`, per-subject PN/ID/PA/TL + ES, `TRLR` count,
valid tag-length-value TL encoding; AECB rendered H/D×3/T with correct record
count; **runtime override test**: AECB delimiter `|`→`;`, TUDF member_id set,
and the TL segment fully replaced via config while non-overridden segments
survived the merge; router honors the BANK `credit_reporting_format` parameter.

### ADR-C6: Bureau Layouts as Overridable Data
**Decision:** format generators are pure renderers over
`FormatSpec.spec(format)`; defaults encode the publicly documented structure
(TUDF/UCRF segment model; AECB has no public spec, so its default is an
explicit skeleton) and any field map, segment, delimiter, or institution id
is replaceable via `config :vmu_core, :bureau_format_overrides`.
**Rationale:** per the 2026-07-05 review answer — official member specs
(CIBIL UCRF guide v3.7x, AECB Data Standards Manual) are gated/version-drifting;
compliance corrections must not require code releases. Public structure
sources: Experian-hosted UCRF Consumer Repository guide (experian.in), TUDF
structure write-ups (allcloud.in, jaguarsoftwareindia.com); AECB technical
docs confirmed portal-gated (etihadbureau.ae).

---

*Update Status + Completed columns as tasks merge.*
