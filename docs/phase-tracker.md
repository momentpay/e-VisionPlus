# vMu VisionPlus — Phase Tracker

> **Repo:** https://github.com/momentpay/e-VisionPlus  
> **Stack:** Elixir ~> 1.18 · Ecto/PostgreSQL · Horde · Oban · Broadway  
> **Architecture:** Hub-and-spoke (vmu_core + path-dep source repos) → umbrella in Phase 2

---

## Phase 1 — Shared Foundation + FAS Authorization Path ✅ DONE
**Commit:** `33fc964` · **Branch:** `main`

| Task | Module | Status |
|---|---|---|
| Horde + libcluster + distributed registry | vMu_shared | ✅ |
| CIF Customer entity (cms_customers) | vMu_shared | ✅ |
| CMS Account + BalanceBucket + STIP schemas + migrations | vMu_cms | ✅ |
| AccountStateCoordinator GenServer (per-account OTB) | vMu_cms | ✅ |
| FAS Authorization path (BIN→Account→ASC→STIP) | vMu_fas | ✅ |
| STIP ETS cache + integration tests | vMu_fas | ✅ |

---

## Phase 2 — CMS Credit Core + CTA Card Issuance ✅ DONE
**Commit:** TBD · **Branch:** `main` · **Weeks:** 5–12

| Task | Module | Status |
|---|---|---|
| Oban dep + Oban migration | vMu_shared | ✅ |
| cms_ledger_entries double-entry GL | vMu_cms | ✅ |
| block_parameters velocity matrix extension | vMu_shared | ✅ |
| cta_card_stock migration + StockInventory schema | vMu_cta | ✅ |
| InterestEngine (ADB calculation, Decimal) | vMu_cms | ✅ |
| InternalGlPoster (idempotent double-entry) | vMu_cms | ✅ |
| EOD LockAccountsJob | vMu_cms | ✅ |
| EOD AccrueInterestJob | vMu_cms | ✅ |
| EOD AgeBucketsJob | vMu_cms | ✅ |
| EOD GenerateStatementJob | vMu_cms | ✅ |
| EOD FlushGlJob | vMu_cms | ✅ |
| StatementGenerator | vMu_cms | ✅ |
| RepaymentDistributor (payment hierarchy) | vMu_cms | ✅ |
| BureauAdapter behaviour + DefaultBureauAdapter | vMu_cta | ✅ |
| EmbossingFileGenerator | vMu_cta | ✅ |
| PinIssuance (SoftHSM wrapper — issuance path) | vMu_cta | ✅ |
| CardActivation workflow (plastic → CMS active) | vMu_cta | ✅ |

---

## Phase 3 — ITS Telephony + DPS Dispute Processing 🔲 PENDING
**Commit:** TBD · **Branch:** `main` · **Weeks:** 13–18

| Task | Module | Status |
|---|---|---|
| IVR session state machine | vMu_its | 🔲 |
| IVR balance/limit/transaction inquiry | vMu_its | 🔲 |
| IVR PIN set/change/verify (HSM-backed) | vMu_its | 🔲 |
| IVR card block / lost-stolen self-report | vMu_its | 🔲 |
| OTP engine (HOTP/TOTP) for digital channels | vMu_its | 🔲 |
| Dispute state machine (filed→chargeback→arb→closed) | vMu_dps | 🔲 |
| Oban deadline scheduler (Visa 120d / MC 30d) | vMu_dps | 🔲 |
| Retrieval request + chargeback filing | vMu_dps | 🔲 |
| Provisional credit posting (DPS → CMS GL) | vMu_dps | 🔲 |
| Dispute GL reconciliation | vMu_dps | 🔲 |

---

## Phase 4 — TRAMS Clearing + COL Collections 🔲 PENDING
**Commit:** TBD · **Branch:** `main` · **Weeks:** 19–24

| Task | Module | Status |
|---|---|---|
| Mastercard IPM Broadway pipeline | vMu_trams | 🔲 |
| Visa Base II file parser | vMu_trams | 🔲 |
| Authorization-to-clearing matching engine | vMu_trams | 🔲 |
| GL extract for core banking | vMu_trams | 🔲 |
| COL collection queue engine (DPD buckets) | vMu_col | 🔲 |
| Dunning letter generator (30/60/90/120 DPD) | vMu_col | 🔲 |
| Workout plan manager | vMu_col | 🔲 |
| Write-off processor + recovery tracker | vMu_col | 🔲 |

---

## Phase 5 — CDM Underwriting + ASM Portal + MBS Merchant 🔲 PENDING
**Commit:** TBD · **Branch:** `main` · **Weeks:** 25–30

| Task | Module | Status |
|---|---|---|
| Credit underwriting rules engine (ApplicationScorer) | vMu_cdm | 🔲 |
| Bureau API integration (Equifax/Experian adapter) | vMu_cdm | 🔲 |
| LimitAllocator (income-based credit limit) | vMu_cdm | 🔲 |
| BehavioralRescorer (Oban periodic re-evaluation) | vMu_cdm | 🔲 |
| ASM operator portal (Phoenix LiveView + FAPI 2.0) | vMu_asm | 🔲 |
| Cardholder web/mobile portal stub | vMu_asm | 🔲 |
| MBS merchant hierarchy + terminal management | vMu_mbs | 🔲 |
| MBS MDR engine | vMu_mbs | 🔲 |
| Credit bureau Metro 2 monthly file | vMu_cms | 🔲 |
| FX rate table management (multi-currency) | vMu_cms | 🔲 |
