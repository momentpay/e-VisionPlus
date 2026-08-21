# Koṣa — Domain Ownership Map (as-built)

| Property | Value |
|---|---|
| Date | 2026-08-01 |
| Status | **As-built record.** Describes what exists in code today, not target state. |
| Product | Koṣa (implementation repo currently named `vmu_core` / E-VisionPlus — see §6) |
| Handbook status | **Advisory.** The Koṣa Architecture Handbook (`Kosa/handbook/`) is target-state reference, not a build specification. |
| Audience | Primarily the architecture team, who map this against the handbook. Written to be readable without knowledge of the codebase. |
| Companion | `docs/compare/Kosa_Handbook_Alignment_Assessment.md` — the gap analysis against the handbook |

---

## 1. Why this document exists

The architecture team writes target-state domain documents; the development team builds. The two streams run independently, and the agreed channel is one-directional: **development publishes what is actually built, and architecture maps against it.**

This is the document that makes that possible. It answers three questions an outside reader cannot get from the code:

1. **Which business capability owns which data?** — §3
2. **Where is ownership unclear or violated today?** — §4
3. **What has development already considered and deliberately deferred?** — §5, so those are not re-proposed as newly-discovered gaps.

It deliberately uses the **handbook's domain vocabulary** (Posting, Financial Account, Limits, Fee…) as the primary index, and the codebase's module names as the secondary one. The two decompositions are different — see §2.

---

## 2. How to read this — the axis mismatch

The implementation is organised by **VisionPlus subsystem lineage**: CMS, FAS, TRAMS, CTA, COL, LMS, HCS, DPS, ASM, CDM, ITS, MBS, KYC, NTS, IVR, Shared. This is inherited from the original VisionPlus reimplementation goal and it is *not* the same axis as the handbook's business-capability decomposition.

The mapping is genuinely many-to-many:

- **One handbook domain, many modules.** *Posting* is implemented across seven modules (see §4.1).
- **One module, many handbook domains.** *CMS* alone carries Financial Account, Posting, Billing, Fee, Interest, Notification and part of Limits.

**Consequence for the architecture team:** a module name in this repo is not a domain boundary, and should not be read as one. The ownership statements in §3 are the boundary; the folder layout is not.

**Consequence for development:** the code is not going to be reorganised to match the handbook. Alignment is achieved by adopting the handbook's *vocabulary and patterns*, not its directory structure.

---

## 3. Ownership register

110 tables. Grouped by owning module, with the handbook domain each serves.

Legend for **Owner**: the module whose code defines the Ecto schema and is responsible for writes.

### 3.1 Foundation / configuration — owner: `Shared`

| Tables | Handbook domain | Notes |
|---|---|---|
| `sys_parameters`, `bank_parameters`, `logo_parameters`, `block_parameters` | **Product (DOC-118)** | The SYS→BANK→LOGO→BLOCK cascade. Serves the Product Definition role in practice. **No version or effective-date columns** — see §4.3. |
| `shared_module_configs` | Product / cross-cutting | Module Configuration Framework — per-module runtime config |
| `plan_segments` | Product | Product plan segmentation |
| `fx_rates` | Financial Account (DOC-106) | Rates only; no currency *positions* |
| `stip_thresholds` | Authorization (DOC-108) | Stand-in processing limits by logo |

### 3.2 Customer & arrangement — owner: `CMS` / `Shared`

| Tables | Handbook domain | Notes |
|---|---|---|
| `cms_customers` | **Customer (DOC-102)** | Owned by `Shared.Customer`. This is the Party/Customer master. No Relationship or Portfolio layer — §5.1 |
| `cms_arrangements` | **Arrangement (DOC-105)** | Deliberately thin: `customer_id`, `product_type`, `account_ref`, `opened_at`. No status, no lifecycle — §5.2 |
| `parties`, `party_identifiers`, `party_flags`, `party_flag_inbox`, `party_flag_outbox`, `party_kyc_attainments`, `party_match_reviews`, `party_product_links` | Customer | **Orphaned — schema exists, zero Elixir code. See §4.5.** |

### 3.3 Accounts & balances — owner: `CMS`

| Tables | Handbook domain | Notes |
|---|---|---|
| `cms_accounts`, `cms_balance_buckets`, `cms_daily_balance_snapshots`, `cms_temp_limits` | **Financial Account (DOC-106)** + Product Instance | Credit. Carries both concerns in one row — §5.3 |
| `cms_debit_accounts`, `cms_debit_adjustments`, `cms_debit_fundings`, `cms_debit_block_history`, `cms_debit_non_monetary_events` | Financial Account | Debit |
| `cms_prepaid_accounts`, `cms_prepaid_adjustments`, `cms_prepaid_ledger_entries`, `cms_prepaid_block_history`, `cms_prepaid_non_monetary_events` | Financial Account | Prepaid (closed-loop) |
| `cms_wallet_accounts`, `cms_wallet_products`, `cms_wallet_fundings`, `cms_wallet_transfers`, `cms_wallet_block_history`, `cms_wallet_non_monetary_events` | Financial Account | Wallet |
| `block_code_history`, `cms_non_monetary_events` | Financial Account | Cross-product lifecycle history |

### 3.4 Money movement — owner: **contested, see §4.1**

| Tables | Handbook domain | Notes |
|---|---|---|
| `cms_ledger_entries` | **Posting (DOC-109) + General Ledger (DOC-110)** | The double-entry ledger of record. Written via `CMS.InternalGlPoster`. **Read/referenced by CMS, FAS and TRAMS.** No Posting Set / Entry / Leg separation; no `posting_rules` table |
| `cms_payments`, `cms_transaction_allocations`, `cms_external_payments`, `cms_autopay_mandates`, `cms_emi_schedules` | **Billing (DOC-113)** | Card statement billing. No Invoice, no Billing Account, no Commercial Obligation |

### 3.5 Authorization — owner: `FAS`

| Tables | Handbook domain | Notes |
|---|---|---|
| `fas_authorizations` | **Authorization (DOC-108)** | Includes `decision_path` JSONB — the only proto-Decision-Record in the platform (§4.4) |
| `fas_pending_holds`, `fas_reversal_exceptions` | Authorization | Holds and reversal exception queue |

### 3.6 Transaction & clearing — owner: `TRAMS`

| Tables | Handbook domain | Notes |
|---|---|---|
| `trams_transactions`, `trams_transaction_events`, `trams_transaction_identifiers` | **Transaction (DOC-107)** | Event-sourced, gapless sequence, state-as-projection. The strongest boundary in the codebase — no other module writes these |
| `trams_clearing_records` | **Clearing (DOC-111)** | Network file matching. No Clearing Cycle / Batch / Position / Netting |
| `trams_statement_lines`, `trams_adjustments`, `trams_maintenance_actions` | Transaction / Billing | Statement extraction and maintenance |

### 3.7 Cards & instruments — owner: `CTA` / `NTS`

| Tables | Handbook domain | Notes |
|---|---|---|
| `cta_cards` | **Payment Instrument** | The unified card master since CU-1. Three-way polymorphism (credit / debit / prepaid account refs) *is* the Payment Instrument layer — §5.4 |
| `cta_card_stock`, `cta_embossing_orders`, `supplementary_cards`, `cms_card_pins` | Payment Instrument | Stock, embossing, supplementary, PIN |
| `nts_tokens` | Payment Instrument | Network tokenisation (Google Pay / MDES / VTS) |

### 3.8 Products — owner: `HCS` / `LMS`

| Tables | Handbook domain | Notes |
|---|---|---|
| `hcs_companies`, `hcs_employee_cards`, `hcs_fleet_cards`, `hcs_vehicles`, `hcs_driver_assignments`, `hcs_spending_controls`, `hcs_facility_limit_changes`, `hcs_consolidated_statements`, `hcs_payment_sweeps`, `hcs_payment_sweep_lines` | Product Instance + **Limits (DOC-119)** | Corporate / fleet. Note: these predate the UUID convention and use integer PKs |
| `lms_schemes`, `lms_plans`, `lms_accounts`, `lms_groups`, `lms_group_merchants`, `lms_rate_tiers`, `lms_points_ledger`, `lms_redemptions`, `lms_merchant_settlement` | **Loyalty (DOC-126)** | Closest module in the codebase to full handbook coverage of its domain |

### 3.9 Operations — owner: `COL` / `DPS` / `ITS` / `CDM` / `KYC` / `MBS` / `ASM`

| Tables | Handbook domain | Notes |
|---|---|---|
| `col_collection_cases`, `col_contact_attempts`, `col_dpd_bucket_history`, `col_workout_plans`, `col_settlement_offers`, `col_writeoff_requests`, `col_agency_placements`, `col_agency_activity` | Collections *(no handbook domain — see §4.6)* | |
| `dps_disputes`, `dps_dispute_evidence`, `dps_dispute_notes`, `dps_reason_codes` | **Dispute (DOC-124) + Chargeback (DOC-125)** | Both handbook domains served by one implementation — §4.2 |
| `its_copy_requests`, `its_fee_claims`, `its_financial_adjustments` | Fee / Dispute support | Retrieval requests, fee claims, adjustments |
| `cdm_credit_applications` | **Risk (DOC-121)** | Origination scoring only |
| `kyc_methods`, `kyc_requests`, `kyc_documents`, `kyc_document_annotations` | Risk / Document | Journey builder, submissions, sanctions gate |
| `mbs_merchants`, `mbs_terminals` | **Merchant (DOC-117)** | Two levels only — §5.5 |
| `asm_operators`, `asm_role_permissions`, `asm_login_audit`, `asm_service_accounts`, `cms_operator_audit` | **Identity (DOC-101)** | Operator identity only, not customer identity — §4.7 |
| `cms_notification_log` | **Notification (DOC-127)** | Delivery log. No Template, Consent or Preference entities |

---

## 4. Where ownership is unclear or violated

This is the section worth reading first. These are **as-built facts**, not opinions, each verified against the code.

### 4.1 Posting has no owner — the most consequential finding

Double-entry posting works and `cms_ledger_entries` is the ledger of record. But **posting rules are hardcoded in seven separate modules**, each writing its own entries:

`cms/internal_gl_poster` · `cms/purchase_posting` · `fas/settlement_posting_adapter` · `its/financial_adjustment_processor` · `its/fee_claim_processor` · `col/write_off_processor` · `lms/gl_provisioner` · `trams/adjustment_command`

There is no Posting Set aggregate, no Posting Entry/Leg separation, and no `posting_rules` table. Every new product, fee type or payment rail writes fresh posting code. Several defects already found in production trace to this (a double-post on hold creation, a Decimal/integer unit mismatch, a silently-failing pending-hold write).

**For the architecture team:** DOC-109 Posting is the domain with the widest divergence between design and implementation, and closing it is the highest-leverage structural change available.

### 4.2 Dispute and Chargeback share one implementation

The handbook separates DOC-124 (Dispute — the customer's contested business event) from DOC-125 (Chargeback — network-facing financial recovery). The implementation merges both into DPS. Representment and arbitration do not exist as lifecycle stages. This split is agreed as correct and is the natural next DPS build; it is a gap, not a disagreement.

### 4.3 Configuration is not versioned or effective-dated

Verified: **no `version` or `effective_from` column exists anywhere in `sys_parameters`, `bank_parameters`, `logo_parameters` or `block_parameters`.** The handbook requires version + effective dating + immutable history for Product, Fee, Pricing, Interest, Limit, Merchant and Tax.

Practical consequence today: it is not possible to answer "what were this product's terms on 3 March", nor to schedule a repriced product with a future effective date. Retrofit cost grows with every product added, because the retrofit must touch every reader.

### 4.4 Decision Records exist in exactly one place

The handbook requires an explainable persisted decision artifact in ten-plus domains. The implementation has one: the `decision_path` JSONB column on `fas_authorizations`. It is a genuine seed and the right thing to generalise, but it is not queryable as evidence and it exists only in Authorization.

### 4.5 Orphaned Party registry — 8 tables, no code

`parties`, `party_identifiers`, `party_flags`, `party_flag_inbox`, `party_flag_outbox`, `party_kyc_attainments`, `party_match_reviews`, `party_product_links` have migrations in this repo and **zero corresponding Elixir modules**. This is a partial port from a predecessor codebase where only the schema crossed over.

**Do not read these tables as evidence of a Party layer.** Customer master is `cms_customers` (§3.2). Resolution pending: finish the port or drop the migrations.

### 4.6 Module coupling — CMS is a hub, and `Shared` inverts

Measured cross-module references:

| Module | References out to |
|---|---|
| `cms` | Shared(22) COL(11) FAS(7) ASM(5) HCS(4) KYC(2) DPS(2) TRAMS(1) LMS(1) |
| `fas` | CMS(21) TRAMS(6) Shared(4) CTA(2) |
| `col` | CMS(15) Shared(10) ASM(3) TRAMS(1) FAS(1) DPS(1) |
| `trams` | CMS(9) FAS(7) DPS(4) ITS(3) CTA(1) |
| `dps` | ASM(8) Shared(5) FAS(3) TRAMS(1) LMS(1) CMS(1) |
| `shared` | **ASM(4) CTA(2) HCS(1) FAS(1) DPS(1) COL(1) CMS(1)** |

Two structural observations:

- **CMS is a hub with bidirectional coupling to nearly every module** (CMS↔FAS, CMS↔COL, CMS↔TRAMS, CMS↔DPS, CMS↔HCS, CMS↔LMS, CMS↔ASM are all cycles). This is the mechanical reason Posting has no home: CMS is where everything meets, so posting code accumulated there and then leaked outward.
- **`Shared` — the foundation layer — depends upward on seven application modules.** A dependency inversion. Foundation code should not know about ASM, CTA, HCS, FAS, DPS, COL or CMS.

`TRAMS` is the counter-example and the model to follow: no other module writes `trams_transactions`, and its event store is the single write path.

Also noted: the KYC module is namespaced `VmuCore.Kyc`, inconsistent with `VmuCore.CMS` / `FAS` / `TRAMS` / `DPS` / `COL`. Cosmetic, but it breaks grep-ability.

### 4.7 Identity covers operators only

ASM is a solid operator-identity implementation (RBAC, LDAP, OIDC login, service accounts, audit). But **customer/cardholder identity has no owner** — it is scattered across `ivr/otp_engine`, `kyc/wallet_step_up` and the Koṣa mobile client. DOC-101 is written for all identity; the implementation covers half of it.

Also: the platform is **single-tenant** (stated explicitly in `asm/ldap_config`), and acts as an OIDC/LDAP *client*, whereas DOC-101 §6.13–6.14 specify an OAuth Authorization Server and OpenID Connect *Provider*.

### 4.8 Collections has no handbook domain

`col_*` implements a full collections and recovery capability — cases, DPD bucketing, dunning, workout plans, hardship, settlement offers, agency placement, write-off. **No handbook domain covers it.** Nearest neighbours are Risk (DOC-121) and Billing (DOC-113), neither of which fits. Flagged as a genuine gap on the *handbook* side.

### 4.9 Some capabilities are owned by external repositories, not this one

**Added 2026-08-01 after an earlier draft of the alignment assessment wrongly reported Fraud as near-absent.** The ownership register in §3 covers tables in this repository, which understates the platform: several capabilities are real, wired and running, but their code lives in sibling repositories consumed as `path:` dependencies in `mix.exs`.

| External repo | Apps consumed | Capability it actually owns | Handbook domain |
|---|---|---|---|
| `../muNSwitch` | `da_switch_core`, `da_issuer` | **The ISO 8583 protocol engine and the issuer-facing Ranch listener** (MIP 7585 / VAP 8600). vmu_core's own listener and hand-rolled parser were deleted in favour of these | Authorization (DOC-108) |
| `../mw-core` | `mw_risk`, `mw_kernel`, `infra_repo`, `infra_feature_store` | **Fraud and risk detection** — configurable rule engine, rule expressions, activation engine, velocity pipeline, sanctions checking with source polling, ML scoring, travel/IP heuristics, side-effect dispatch, and an explainer. Called directly from `FAS.RiskAdapter` | **Fraud (DOC-120)**, Risk (DOC-121) |
| `../wallet-app` | `wallet_cards`, `wallet_gl`, `wallet_shared_kernel`, `wallet_events`, `wallet_database`, `wallet_observability` | **Being retired** — [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md). Measured coupling is two source files: a `GlAdapter` behaviour, a `GlPostingRecord` struct and a `Money` value type. Four of the six are referenced nowhere in code. Plan: [`Wallet_App_Dependency_Migration.md`](Wallet_App_Dependency_Migration.md) | General Ledger (DOC-110) |
| `../tmsuat_apps-main` | `settlement_core`, `platform_core` — **`runtime: false`** | Code reuse only; their OTP apps are deliberately not started (Oban name collision). Interchange/MDR rate structures | Settlement (DOC-112), Fee (DOC-115) |

**Three consequences worth naming:**

1. **Reading only this repository understates the platform.** Fraud detection in particular is substantial and live; what is missing is the *operational* half (alerts, cases, investigation, analyst UI), not detection.
2. **Resolved 2026-08-01 — [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md).** `muNSwitch` and `mw-core` are now **deliberate boundaries**: externally owned, separately versioned, named here so that reading this repository alone no longer understates the platform. `wallet-app` is **retired** and its six dependencies are being removed. `tmsuat_apps-main` is unchanged. What remains undecided is the *release strategy* for the two retained boundaries — they are still `path:` dependencies, which is a development convenience rather than a release model.
3. **A `path:` dependency is a build-time coupling to a sibling working directory.** These four repos must be checked out adjacent to this one for the build to resolve. That is a deployment and onboarding constraint that no document currently states.

---

## 5. Deliberate deferrals — considered and rejected, not overlooked

**This section exists so these are not re-proposed as newly-discovered gaps.** Each was analysed and consciously deferred, with the reasoning recorded.

| # | Item | Decision | Reasoning |
|---|---|---|---|
| 5.1 | **Relationship and Portfolio layers** (between Customer and Arrangement) | Deferred, not rejected | Confirmed valuable. No current requirement forces it — no customer today needs multiple concurrent commercial relationships (e.g. Retail + Merchant on one Party). Add when one does. |
| 5.2 | **Arrangement as a full aggregate** (Party, Role, Term, Condition, Limit, Fee, Schedule, Preference, Status History + 12-state lifecycle) | Deliberately thin | Built as a cross-product index, not a contract engine. Status and balance stay authoritative on the real product row and are read live — duplicating them into Arrangement would let them drift. Revisit with the first commercial product where the contract *is* the product. |
| 5.3 | **Splitting Financial Account from Product Instance** | Deferred | Each product table carries both concerns in one row. Splitting is a large migration with no current driver: no product spans multiple financial accounts, and no account is shared across products. |
| 5.4 | **A `payment_instruments` umbrella table** above `cta_cards` | Deferred | `cta_cards`'s existing three-way polymorphism already *is* this layer. Every instrument in the platform today is a card. Build the umbrella when a second non-card instrument (QR / UPI / VPA) actually needs issuing. |
| 5.5 | **Merchant hierarchy and agreements** | Check before building | A real Merchant Management System with onboarding and KYC exists **outside this repo**. Audit it before scoping merchant work here. |
| 5.6 | **Rail-independent Transaction / Authorization / Posting extraction** | Deferred pending a business trigger | The handbook (DOC-109A Objective 3) requires it and the implementation cannot meet it today. But extracting it from TRAMS/FAS is a large, high-risk change to the two best-working parts of the codebase. The correct trigger is a committed second payment rail — A2A / Instant Payments is the open decision. Doing it speculatively is not recommended. |

---

## 6. Naming

The product is **Koṣa**. The implementation repository is currently named `vmu_core` and documented as "E-VisionPlus", inherited from its origin as a VisionPlus reimplementation. The Elixir namespace is `VmuCore.*`.

**Current position:** adopt "Koṣa" in documentation and product-facing language; **defer the code namespace rename indefinitely.** It is cosmetic, it carries real regression risk (a prior app-atom rename in this codebase required sweeping every `Application.get_env`/`put_env` site), and it buys no functional gain. Revisit only if there is an independent reason to touch the namespace.

---

## 7. Maintenance

| | |
|---|---|
| Owner | Development team |
| Update trigger | Any new table, any new cross-module write path, any deferral in §5 being taken up |
| Review cadence | Each phase boundary, alongside re-running the alignment assessment |
| Related | `docs/compare/Kosa_Handbook_Alignment_Assessment.md` (gap analysis) · `docs/decisions/` (ADR register, pending) · `docs/MODULE_DOCUMENTATION_INDEX.md` (per-module requirement inventories) |
