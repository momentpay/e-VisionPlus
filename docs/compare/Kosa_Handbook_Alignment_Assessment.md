# Koṣa Enterprise Handbook ↔ vmu_core — Alignment Assessment

| Property | Value |
|---|---|
| Date | 2026-08-01 |
| Handbook source | `D:\momentPay\Products\Kosa\Kosa\handbook\domains` (DOC-101 … DOC-128 + DOC-extra Tax, 30 docs, ~1.8 MB) |
| Implementation assessed | `vmu_core` (standalone — the platform of record per the 2026-07-23 reversal, superseding the merged Avenza umbrella) |
| Companion documents | `docs/compare/Way4_Parity_Implementation_Plan.md` (feature parity vs. competitors), `docs/cms/core-domain-new-docs.md` §11 (earlier, narrower Koṣa alignment table) |
| Purpose | Read the handbook as one coherent design, state what vmu_core actually has against it, name the gaps with perspective, and give a sequencing view for further development |

---

## 0. Method, and what this document is not

This assessment was built by reading the handbook's structural sections (domain purpose, business capabilities §10, business services §10.2/§11, canonical information model §19–22, domain boundaries §6) across all 30 domain documents, and mapping them against vmu_core's actual module tree (`lib/vmu_core/*`), migration set (110 tables), module docs, and admin UI surface.

It is a **capability-to-code** mapping. It is not a line-by-line code audit — where this document says a capability is "partial", that means the code exists and is real, not that every branch of it was read. Where it says "absent", that was verified by targeted search across `lib/` and `priv/repo/migrations/`.

Two caveats worth stating up front:

1. **The handbook's own index is stale.** `handbook/README.md` and `DOC-100 – Alll-Def.md` still describe a 15-document set (DOC-101…115) with different names than the files that actually exist. The real set is DOC-101…128 + Tax, and it renumbered/expanded significantly: what the index calls "DOC-107 Payment Instrument" is now DOC-107 Transaction; "DOC-111 Billing & Fee" split into DOC-113 Billing / DOC-114 Pricing / DOC-115 Fee; "DOC-112 Risk & Compliance" split into DOC-120 Fraud / DOC-121 Risk. DOC-103/117 (Merchant) and DOC-104/118 (Product) are two generations of the same domain, the later ones being the tighter rewrite. **Read the files, not the index.** This document uses the files.

2. **"Not in vmu_core" ≠ "not built anywhere."** Per the 2026-07-23 platform-of-record reversal, several capabilities exist in Avenza / wallet-app / MMS and have not been ported yet. This is flagged explicitly per-domain below, because treating a port as a net-new build is exactly the correction-fatigue pattern that has already cost this project seven times.

---

## Part I — Reading the handbook as one design

### 1. The handbook has a spine and a set of rings

The 30 documents are not 30 equal peers. They resolve into a clear shape:

**The spine — DOC-109A, "Financial Execution Reference Architecture."** This is the most important document in the set and the one to read first. It explicitly says the domain docs describe individual capabilities, while *it* describes how they collaborate. It defines one canonical execution pipeline:

```
Customer → Arrangement → Financial Account
                              ↑
   Transaction → Authorization → Posting → General Ledger
                                    ↓
                            Clearing → Settlement
```

with four stated objectives: one business capability per domain and none shared; immutable financial facts (corrections are new events, never updates); **payment-rail independence** — the same pipeline must serve Card, UPI, A2A, ACH, Wallet, Acquiring, Lending, Treasury, BNPL without redesign; and independent scalability per stage.

**The calculation ring — DOC-113 Billing, 114 Pricing, 115 Fee, 116 Interest, Tax.** These share one template almost verbatim: Catalog → Plan → Rule → Result → Version, plus a Decision Record. They are deliberately designed as *pure calculators* that feed the Posting domain; none of them post.

**The control ring — DOC-119 Limits, 120 Fraud, 121 Risk.** Same template again: Policy → Model/Rule → Assignment → Evaluation → Decision Record. These are consulted by Authorization, never invoked by it directly.

**The recovery ring — DOC-123 Reconciliation, 124 Dispute, 125 Chargeback.** The handbook deliberately splits Dispute (the customer's contested business event) from Chargeback (the network-facing financial recovery). That split matters and vmu_core does not make it.

**The master-data ring — DOC-101 Identity, 102 Customer, 117 Merchant, 118 Product.** Everything else is downstream of these.

**The periphery — DOC-122 Treasury, 126 Loyalty, 127 Notification, 128 Reporting.**

### 2. Five patterns the handbook repeats in every domain

These recur with enough consistency that they are effectively platform-wide architectural mandates rather than per-domain features. They matter more than any individual entity list, because they are the parts vmu_core systematically does not do:

| Pattern | What it demands |
|---|---|
| **Aggregate root discipline** | Every domain names exactly one aggregate root (Arrangement, Financial Account, Transaction, Authorization, Posting Set) and states that *no external domain may modify child entities directly*. |
| **Catalog → Plan → Rule → Result** | Every calculation domain externalizes its logic into configurable, queryable rows — not code. Fee, Pricing, Interest, Tax, Limit and Risk all use this identical shape. |
| **Version + effective dating + immutable history** | Product, Fee, Pricing, Interest, Limit, Merchant, Tax all require versioned business objects with effective dates and retained history. |
| **Decision Records** | Ten-plus domains require an explainable, persisted artifact per decision — Authorization Decision, Fee Result, Interest Decision Record, Limit Decision Record, Fraud/Risk/Merchant/Product/Recovery/Communication Decision Records. Explainability is treated as a first-class deliverable, not logging. |
| **Enterprise event backbone** | DOC-109A §8 and §56–58 define a Transaction Bus, a Decision Event Bus, and a Financial Execution Bus as the only inter-domain coupling. |

### 3. The axis mismatch — why a folder-to-folder comparison would mislead

vmu_core is decomposed by **VisionPlus subsystem lineage**: CMS, FAS, TRAMS, CTA, COL, LMS, HCS, DPS, ASM, CDM, ITS, MBS, KYC, NTS, IVR. The handbook is decomposed by **business capability**. These are different axes, and the mapping is genuinely many-to-many:

- One Koṣa domain spread across several vmu_core modules — *Posting* lives in `cms/internal_gl_poster`, `cms/purchase_posting`, `fas/settlement_posting_adapter`, `its/financial_adjustment_processor`, `col/write_off_processor`, `lms/gl_provisioner`, and `trams/adjustment_command`.
- One vmu_core module covering several Koṣa domains — CMS alone carries Financial Account, Posting, Billing, Fee, Interest, Notification, and part of Limits.

The practical consequence: **do not reorganize the code to match the handbook.** The value of the handbook here is as a completeness checklist and a boundary discipline, not as a directory layout.

---

## Part II — What vmu_core actually has, domain by domain

Legend: **Strong** = built and production-shaped · **Partial** = real code, materially narrower than the handbook · **Thin** = a mechanism exists but not the domain · **Absent** = no code found

### The spine

| Koṣa domain | vmu_core owner | State | Assessment |
|---|---|---|---|
| **DOC-102 Customer** | `Shared.Customer` (`cms_customers`), `CMS.Arrangements` | Partial | Customer master is real. **Relationship** and **Portfolio** layers are absent — a documented, deliberate deferral (`core-domain-new-docs.md` §11). Contact Management, Customer Analytics and Compliance Reference Management (§5.8–5.11) exist only as admin-screen fields, not as capabilities. **Live finding: the `parties`, `party_identifiers`, `party_flags`, `party_flag_inbox`/`outbox`, `party_kyc_attainments`, `party_match_reviews`, `party_product_links` tables exist in vmu_core migrations with zero corresponding Elixir code** — the M5.1b Party/Identity unification work was ported as schema only. This is either dead weight to drop or a half-port to finish; today it is neither. |
| **DOC-105 Arrangement** | `CMS.Arrangement` (`cms_arrangements`) | Thin | Deliberately 4 columns: `customer_id`, `product_type`, `account_ref`, `opened_at`. The handbook asks for a 10-entity aggregate (Party, Role, Term, Condition, Limit, Fee, Schedule, Preference, Status History) and a 12-state lifecycle (Draft → PendingValidation → Validated → PendingApproval → Approved → PendingActivation → Active → Suspended → PendingRenewal → Renewed → PendingClosure → Closed). vmu_core's has **no status field at all**. This is the widest single gap in the spine, and it is the one that blocks Corporate/commercial products where the contract itself is the product. |
| **DOC-106 Financial Account** | `CMS.Account`, `DebitAccount`, `PrepaidAccount`, `WalletAccount`, `cms_balance_buckets` | Partial | Every product table carries both Financial Account and Product Instance concerns in one row — a documented deferral. Against the handbook's canonical 12-balance model (Ledger, Available, Reserved, Pending Debit, Pending Credit, Credit Limit, Utilized Credit, Outstanding, Accrued Interest, Accrued Fees, Shadow, Settlement), vmu_core covers most **per product, with different column names and different arithmetic per product** — there is no single canonical balance vocabulary. **Currency Position** (multi-currency within one account) and **Posting Profile** are absent; `fx_rates` + `CMS.FxEngine` handle conversion but not positions. |
| **DOC-107 Transaction** | TRAMS (`trams_transactions`, `transaction_events`, `transaction_identifiers`, `state_machine`, `event_store`) | Strong (card-shaped) | TRAMS is the closest thing in the codebase to handbook-grade design: a real append-only event store with gapless per-transaction sequencing, `FOR UPDATE` locking, a validated state machine, and state-as-projection (ADR-T1). Genuinely better than the handbook asks for on immutability. **But it is card-clearing-shaped** — it is the ISO/IPM/Base II lifecycle, not the rail-independent Transaction the handbook defines. Transaction Party, Transaction Charge and Transaction Relationship are not first-class entities. |
| **DOC-108 Authorization** | FAS (`fas_authorizations`, `pending_holds`, `stip`, `exception_queue`, `iso8583/`, `emv_handler`, `hsm/`, `risk_adapter`) | Strong (card-shaped) | Real ISO 8583, real EMV, real HSM commands, STIP, hold aging, reversal handling, exception queue. Covers §10.1–10.15 substantially. Gaps against the information model: **Rule Evaluation** and **Decision Reason** are not entities — they are collapsed into one `decision_path` JSONB column. That column is a genuine proto-Decision-Record and the right seed to build on, but it is not queryable as evidence and it exists only here, in one domain out of the ten that require it. |
| **DOC-109 Posting** | Scattered: `cms/internal_gl_poster`, `cms/purchase_posting`, `cms_ledger_entries`, `fas/settlement_posting_adapter`, `its/*_processor`, `col/write_off_processor`, `lms/gl_provisioner`, `trams/adjustment_command` | Partial, no domain | Double-entry posting is real and works — `cms_ledger_entries` via `InternalGlPoster` is the ledger of record (confirmed 2026-07-22, Phase 1 item 3). But **there is no Posting domain**: no Posting Set aggregate, no Posting Entry/Leg separation, **no Posting Rule table** (posting rules are hardcoded in each caller), no generic multi-leg posting. Every new product or rail writes its own posting code. This is the highest-leverage structural gap in the whole assessment. |
| **DOC-110 General Ledger** | `fas/gl/card_account_codes`, `trial_balance`, `gl_reconciliation`, `cms_ledger_entries` · **plus `WalletGl.ChartOfAccounts` (external, being retired)** | Thin in this repo — **but a real registry exists elsewhere** | *Corrected 2026-08-01.* In **standalone vmu_core** the chart of accounts is five hardcoded codes in a module docstring. But `WalletGl.ChartOfAccounts` is a genuine **26-account registry** — `code`, `name`, `account_class`, `normal_balance`, **`owner_app`**, `currency`, `active`, `description`, with `register/2` and `valid?/1` — attributed across vmu_fas/cms/col/hcs/its/dps/lms, and **Avenza already reconciled its GL onto it** (M5 Phase 2, 2026-07-18). That work never came back to this repo. So "no chart of accounts as data" is wrong as a platform statement; it is accurate only of this tree. **Action: absorb it natively before wallet-app is retired** — see [`architecture/Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) §0.3. Still genuinely absent everywhere: Journal / Journal Entry / Journal Line hierarchy, **Accounting Period**, **Fiscal Calendar**, Financial Statement. No accounting period still means no period close, no locking and no defensible cut-off — a regulatory-audit exposure. Trial balance exists and works. **Live defect found while checking: this tree books interest income to `4001 Fee Revenue` instead of `4002 Interest Income` — fixed in Avenza 2026-07-18, never ported (§0.4).** |
| **DOC-111 Clearing** | `trams_clearing_records`, `mastercard_ipm`, `visa_base_ii`, `ipm_pipeline`, `matching_engine` | Partial | Real network file handling and real matching. Absent as entities: Clearing Cycle, Clearing Batch, Clearing Position, **Net Position / netting engine**, Clearing Participant. vmu_core clears card transactions; it does not run a clearing house. Whether it needs to is a business question (see Part IV). |
| **DOC-112 Settlement** | `lms_merchant_settlement`, `hcs_payment_sweeps`, `fas/settlement_posting_adapter`, `settlement_date` fields | Thin | Settlement today is a date field, merchant payout math, and corporate sweeps. None of Settlement Order, Settlement Instruction, Settlement Execution, Settlement Confirmation, **Settlement Calendar / Window**, or **Liquidity Verification** exists. Combined with the Treasury gap below, vmu_core currently has no view of "can we actually fund this settlement." |

### The calculation ring

| Koṣa domain | vmu_core owner | State | Assessment |
|---|---|---|---|
| **DOC-113 Billing** | `cms/statement_generator`, `cms_payments`, `payment_allocation`, `transaction_allocation`, `autopay`, `emi_schedules` | Partial | Card statement billing is strong — cycles, allocation, autopay, EMI, reversal. But it is *card statement* billing, not the handbook's Billing domain: no **Commercial Obligation**, no **Billing Account**, no **Invoice**. Any non-card billable (merchant service fees, subscription products, corporate facility fees) has nowhere to live. |
| **DOC-114 Pricing** | — (`mbs/mdr_engine` is the nearest relative) | **Absent** | No Price Catalog, Plan, Rule, Result or Version. MDR resolution via ParameterEngine is the only price calculation in the codebase, and it is merchant-acquiring-specific. |
| **DOC-115 Fee** | `cms/fee_engine`, `cms/fee_waiver`, `its_fee_claims` | Thin | Four hardcoded fee assessments (late, overlimit, annual, returned payment) resolved through the ParameterEngine cascade. Against the handbook: no Fee Catalog / Plan / Rule / Result / Version entities, and **no Revenue Sharing, Commission, or Incentive management at all** — which is the part a multi-party platform actually needs. |
| **DOC-116 Interest** | `cms/interest_engine` (ADB), `penalty_apr_manager`, COL hardship plans | Thin | One hardcoded strategy (Average Daily Balance), correct and Decimal-safe, with grace-period and cash-advance handling. Against the handbook: no Interest Catalog / Product / Plan / **Strategy** / Rule objects, no capitalization models, no simulation service, no Interest Decision Record. Adding a second interest method today means editing the engine. |
| **DOC-extra Tax** | — | **Absent** | Entire domain. No VAT/GST on fees, no exemption handling, no jurisdiction determination. For any GCC/India deployment this is a hard regulatory requirement, not an enhancement. |

### The control ring

| Koṣa domain | vmu_core owner | State | Assessment |
|---|---|---|---|
| **DOC-119 Limit Management** | `cms_temp_limits`, `wallet_velocity_limits`, `hcs/limit_controller`, `hcs_spending_controls`, `cdm/limit_allocator`, ParameterEngine limits | Partial, no domain | Limits work — but **five independent silos, one per product**, with no shared vocabulary. The handbook asks for Limit Definition → Policy → Assignment (with an inheritance model across levels) → Evaluation → Exposure → Velocity → Threshold → Decision Record. Because every product owns its own limit code, "what is this customer's total exposure across all products" is not answerable today (`cms/customer_exposure` is credit-only). |
| **DOC-120 Fraud Management** | `fas/risk_adapter` → **`mw_risk`** (external path dependency, `mw-core/apps/mw_risk`), `risk_feed_subscriber`, `hot_card_cache`, `cdm/behavioral_rescorer` | Partial — **detection real, case management absent** | *Corrected 2026-08-01: an earlier draft of this document called this near-absent. That was wrong.* `FAS.RiskAdapter` calls `MwRisk.Pipeline.run/2` directly — a built path dependency carrying a substantial engine: configurable rules (`gateway_rule_engine`, `rule_expression`, `rule_cache`, `activation_engine`), velocity (`velocity_pipeline`), sanctions (`sanctions_checker`, source polling), ML scoring, travel/IP heuristics, side-effect dispatch, and an `explainer` module. Detection is fail-safe (any scoring error → passthrough approve). **What is genuinely absent is the operational half**: no fraud alerts, no case management, no investigation workflow, no analyst UI. Also an open ownership question — fraud detection currently lives *outside* the platform of record (§ownership map §4.9). |
| **DOC-121 Risk Management** | `cdm/application_scorer`, `behavioral_rescorer`, `sanctions_screening`, `kyc/risk_screening`, bureau adapters | Partial | Credit-origination risk is real (scoring, bureau, sanctions — and the KYC sanctions gate is proven working on real seed data). Absent: Risk Policy / Model / Profile registries, **portfolio risk**, **counterparty risk**, continuous monitoring service, Risk Decision Records. Risk exists at the point of application, not as an ongoing enterprise function. |

### The recovery ring

| Koṣa domain | vmu_core owner | State | Assessment |
|---|---|---|---|
| **DOC-123 Reconciliation** | `trams/reconciliation` (three-way), `fas/gl/gl_reconciliation` | Partial | The three-way TRAM ↔ clearing ↔ ledger reconciliation is genuinely good and produces break lists rather than a pass/fail. Absent: configurable **matching rules** (the match logic is code), and Exception / **Break** as managed case entities with assignment, aging and resolution workflow. Recon today produces a report; it does not manage the work that comes out of the report. |
| **DOC-124 Dispute** | DPS (`dps_disputes`, `dispute_evidence`, `dispute_notes`, `reason_codes`, `deadline_job`, `network_adapter`, `evidence_store`) | Strong | Registration, evidence, notes, reason codes, SLA deadlines, network adapter. Close to the handbook. Gaps: configurable workflow stages (stages are coded), collaboration/participant model. |
| **DOC-125 Chargeback** | DPS (shared with Dispute), `trams/dispute_bridge` | Partial | **vmu_core merges Dispute and Chargeback; the handbook deliberately separates them.** The customer-facing case and the network recovery case have different lifecycles, different SLAs and different owners. Absent: **representment** and **arbitration** as lifecycle stages, a scheme rule engine (Visa/Mastercard rules as data), and recovery accounting. This is the correct next build in DPS. |

### The master-data ring

| Koṣa domain | vmu_core owner | State | Assessment |
|---|---|---|---|
| **DOC-101 Identity** | ASM (`asm_operators`, `role_permissions`, `login_audit`, `service_accounts`, `auth`, `authz`, `ldap_client`, `oidc_client`, `role_taxonomy`) | Partial | Operator identity is solid — RBAC, LDAP, OIDC login, service accounts, audit. Against DOC-101's 12 canonical entities, absent: **Tenant** (explicitly single-tenant today, `ldap_config` says so), **Policy** as an object (authorization is role/permission only, not policy-based), Session and Credential as first-class entities. Structurally: vmu_core is an **OIDC/LDAP client**, whereas DOC-101 §6.13–6.14 specify an OAuth Authorization Server and OpenID Connect **Provider**. Also — DOC-101 is written for *all* identity, but vmu_core only has operator identity; cardholder/customer identity is scattered across `ivr/otp_engine`, `kyc/wallet_step_up` and the Kosa Flutter app, with no single owner. |
| **DOC-117 Merchant** | MBS (`mbs_merchants`, `mbs_terminals`, `mdr_engine`), `lms_group_merchants`, `lms_merchant_settlement` | Thin | Two levels (Merchant → Terminal), MCC, MDR, settlement IBAN. The handbook asks for Merchant Profile, Organization, **Hierarchy** (Group → Merchant → Location → Outlet → Acceptance Point), **Agreement**, Settlement Profile, Capability, Compliance Profile, Operational Profile, Version, Decision Record — plus an onboarding lifecycle. **Port-vs-build flag: a real MMS with merchant onboarding and KYC exists outside vmu_core** (`docs/kyc/MMS_KYC_Feature_Reference.md`). Check that before scoping any merchant work. |
| **DOC-118 Product** | `shared/parameter_engine` (SYS→BANK→LOGO→BLOCK cascade), `plan_segments`, `cms_wallet_products`, `shared_module_configs` | Thin | The parameter cascade is a genuinely good **configuration** mechanism and serves the Product Definition role in practice. But it is not a product catalog: no Product Definition / Family / Category / Variant / **Bundle** / Feature / Eligibility as entities, no product lifecycle (Draft → Approved → Published → Retired), and — verified — **no version or effective-date columns anywhere in `sys_parameters` / `bank_parameters` / `logo_parameters` / `block_parameters`**. You cannot today answer "what were this product's terms on 3 March" or launch a repriced product with a future effective date. |

### The periphery

| Koṣa domain | vmu_core owner | State | Assessment |
|---|---|---|---|
| **DOC-122 Treasury** | — | **Absent** | Entire domain. No liquidity management, cash position, funding, treasury accounts, counterparty exposure, FX position, or forecasting. Directly blocks DOC-112's Liquidity Verification. |
| **DOC-126 Loyalty** | LMS (`schemes`, `plans`, `groups`, `rate_tiers`, `points_ledger`, `redemptions`, `clawback`, `points_engine`, `merchant_settlement`) | Strong | Earn, accrue, redeem, clawback, merchant funding, rate tiers, group merchants. Close to the handbook's core. Gaps: **Tier Management** (customer tiers, distinct from rate tiers), **Campaign / Offer management**, Gamification, and partner coalition beyond merchant groups. |
| **DOC-127 Notification** | `cms/notification`, `notification_dispatcher` + channel adapters, `cms_notification_log` | Partial | Multi-channel (email/SMS/WhatsApp/webhook) real dispatch with per-channel config and skip-on-unconfigured. Absent: **Template** as a managed entity, **Consent** and **Preference** management (a regulatory requirement, not a feature), channel routing policy, and Journey orchestration. Today notifications are triggered by code, addressed to whatever the account row holds. |
| **DOC-128 Reporting & Analytics** | `col/collections_mi`, `hcs/fleet_report`, `fas/gl/trial_balance`, `cms/metro2_generator`, admin screens | Thin | Purpose-built reports per module. Absent: semantic layer, Report / Dashboard / KPI **definitions** as data, self-service analytics, and a regulatory reporting framework (Metro2 is one hardcoded feed, not a framework). |

---

## Part III — The gaps that actually matter

Rolling the table up. Not all gaps are equal, and the domain-by-domain view over-weights breadth.

### Tier 1 — Structural. These compound, and every month they stay open costs more.

**1. There is no Posting domain.** Posting rules are hardcoded across seven modules. Every new product, rail or fee type writes its own double-entry code, and there is no single place to see or change how money moves. This is the root cause of several of the bugs already found live (the `create_hold` double-post, the Decimal/integer unit mismatch, the FAS pending-hold silent write failure). **Highest leverage fix in the entire list.**

**2. The GL has no accounting period or chart of accounts as data.** Five account codes in a docstring, no period, no close, no lock. This is an audit exposure with a regulatory edge, and it is cheap to fix relative to its risk.

**3. Configuration is not versioned or effective-dated.** Verified absent across the entire parameter cascade. It makes historical dispute defence, retroactive correction, and future-dated product launches impossible — and it will get *harder* to retrofit with every product added, because the retrofit has to touch every reader.

**4. The spine is card-shaped, not rail-independent.** TRAMS and FAS are excellent ISO/IPM implementations, and DOC-109A's Objective 3 explicitly demands the pipeline serve UPI, A2A, ACH, wallet and BNPL "without redesign." Today each of those would mean a parallel implementation. This is the gap that decides whether Koṣa is a card platform with extras or an enterprise payment platform. **It is also the one that should not be fixed pre-emptively** — see Part IV.

**5. No Decision Record pattern.** Ten-plus domains require it; one JSONB column exists in one domain. Explainability is a compliance obligation for credit, fraud, risk and limits, and it is far cheaper to establish the pattern once now than to retrofit ten domains later.

### Tier 2 — Whole domains absent, business-blocking

- **Treasury (DOC-122)** — nothing. Blocks settlement liquidity verification.
- **Tax (DOC-extra)** — nothing. Hard regulatory requirement in target markets.
- **Pricing (DOC-114)** — nothing beyond MDR.
- **Fraud (DOC-120)** — *detection is not absent* (see the corrected row above: `mw_risk` provides rules, velocity, sanctions, ML and explainability via a direct call from FAS). What is absent is the **operational half** — alerts, cases, investigation workflow, analyst UI — plus the ownership question of fraud living outside the platform of record.
- **Limit Management as a domain (DOC-119)** — the capability exists five times over in five silos; the *domain* does not, and consequently cross-product customer exposure is unanswerable.

### Tier 3 — Real but narrower than designed

Arrangement (thin vs. a 10-entity aggregate and a 12-state lifecycle) · Financial Account (no canonical balance vocabulary, no currency position) · Merchant (2 levels vs. 5, no agreement — but check MMS first) · Product (config cascade, not a catalog) · Fee/Interest (hardcoded strategies, no catalog/plan/rule) · Billing (card statements only, no invoice) · Clearing/Settlement (no cycles, positions, netting, windows) · Notification (no templates, no consent) · Reporting (no semantic layer) · Chargeback (not separated from Dispute; no representment/arbitration) · Reconciliation (no break case management) · Identity (single-tenant, no policy, client-not-provider, no unified customer identity).

### Tier 4 — Housekeeping

- **Orphaned Party registry.** Seven `part*` tables with zero Elixir code. Either finish the port from Avenza or drop the migrations — leaving schema-without-code invites someone to assume the feature exists.
- **Handbook index drift.** `README.md` and `DOC-100` describe a document set that no longer exists. Worth flagging to the architecture team; anyone onboarding from the index will build against the wrong domain map.

---

## Part IV — Perspective

Four judgements, offered as the point of the exercise rather than as more table rows.

**1. vmu_core is deep exactly where the handbook is shallow, and shallow where the handbook is deep — and that is not a failure on either side.** vmu_core has real ISO 8583, real HSM commands, real IPM/Base II parsing, EOD orchestration, dunning, Metro2, embossing files, EMV. The handbook does not describe any of that in operational detail; it is written one level up. Conversely the handbook demands catalogs, versions, aggregates and decision records that vmu_core almost entirely lacks. **The handbook is a target-state enterprise reference model, not a specification of the product you are shipping.** Treating it as a build backlog would mean deprioritizing working payment infrastructure to build catalog tables — the wrong trade. Treat it as (a) a completeness checklist, (b) a boundary discipline for new work, and (c) the definition of done for anything genuinely enterprise-wide.

**2. Fix the patterns, not the domains.** Tier 1 items 1, 3 and 5 — the Posting domain, effective-dated config, and Decision Records — are each a single cross-cutting investment that immediately raises the alignment of eight to twelve domains at once. Building the Treasury domain, by contrast, raises alignment of exactly one. Pattern work is where the compounding is, and it is also where the retrofit cost grows fastest with delay. **Do pattern work before breadth work.**

**3. Rail independence is the real strategic question, and it is a business decision, not an architecture one.** DOC-109A Objective 3 is unambiguous, and today vmu_core cannot meet it without parallel implementations. But refactoring TRAMS/FAS into rail-independent Transaction/Authorization/Posting layers is a very large, high-risk change to the two best-working parts of the codebase. **Do not start it speculatively.** The right trigger is a committed second rail. Digital Wallet Phase 2 already has A2A/Instant Payments open as the last vendor decision — *that* is the decision that should force this, and when it lands, do the extraction as part of building that rail rather than as a standalone refactor. Until then, the correct move is defensive: make sure every *new* posting, fee and limit goes through a shared abstraction rather than a product-specific one, so the eventual extraction has less to unwind.

**4. Check the other repos before scoping anything in the master-data ring.** Merchant (MMS), Notification, parts of Identity, and the Party registry all have real prior implementations outside vmu_core. The seven-times-repeated merge-drift pattern means the default assumption for any "missing" capability in this ring should be *"this may already exist elsewhere"* — check `Avenza/apps/vmu_*`, wallet-app and MMS, and the git log, before writing a build ticket.

---

## Part V — Suggested alignment sequencing

Framed to sit alongside `Way4_Parity_Implementation_Plan.md`, not to replace it. Way4 asks "are we competitive?"; this asks "are we coherent?" Both matter, and they interleave — several items below directly unblock Way4 Phase 2/3.

**Track A — Pattern foundations (do first; each is cross-cutting and cheap relative to its leverage)**

| # | Item | Why now |
|---|---|---|
| A1 | Extract a **Posting service** — `PostingSet` / `PostingEntry` / `PostingLeg` + a `posting_rules` table — and migrate the seven existing posting call sites onto it, one at a time | Root cause of several live bugs; every subsequent product gets cheaper; prerequisite for rail independence |
| A2 | **Chart of Accounts as data** — *now a port, not a build*: absorb `WalletGl.ChartOfAccounts` (26 accounts, `owner_app`, `register/2`) into `VmuCore.GL` before wallet-app is retired. Then `accounting_periods` with open/close/lock, which **is** still a build | Half of this already exists outside the repo and is about to be deleted with it. Periods remain the audit/regulatory exposure. See migration §0.3 |
| A3 | **Effective dating + version columns** on the parameter cascade, plus an as-of resolver in `ParameterEngine` | Retrofit cost grows with every product added; unblocks future-dated launches and historical dispute defence |
| A4 | Generalize FAS's `decision_path` into a shared **Decision Record** concern, then apply it to Limits and Risk as the first two consumers | Establishes the pattern while it is still two domains rather than ten |

**Track B — Absent domains, ordered by business necessity**

| # | Item | Why this order |
|---|---|---|
| B1 | **Tax** (catalog → rule → result → exemption) | Hard regulatory blocker for GCC/India go-live; small, self-contained, and A3 makes it much easier |
| B2 | **Fraud operations** — alerts, cases, investigation workflow, analyst UI. **Not** the detection engine, which exists in `mw_risk` | Detection is already wired; the gap is that nothing catches what it flags. Decide the `mw_risk` ownership question first (own it, absorb it, or formalise it as an external service) |
| B3 | **Limit Management** as one domain, consolidating the five silos behind a shared evaluation service | Unblocks cross-product customer exposure; consumes A4 |
| B4 | **Pricing** (catalog → plan → rule → result) | Should follow Fee's restructure so the two share the calculator shape the handbook defines |
| B5 | **Treasury** | Needed before Settlement can be built properly; lower urgency until settlement volume justifies it |

**Track C — Deepen what exists (interleave opportunistically with product work)**

- Split **Chargeback from Dispute** in DPS; add representment + arbitration + scheme rules as data. *(Natural next DPS build.)*
- **Fee** and **Interest**: move from hardcoded strategies to Catalog → Plan → Rule → Result. Do Fee first; Interest follows the same shape.
- **Arrangement**: add `status` + lifecycle + Arrangement Party/Role at minimum. Trigger this with the first commercial/corporate product where the contract *is* the product.
- **Notification**: Template entity + Consent/Preference management. Consent is a regulatory item, not a feature.
- **Reconciliation**: promote breaks to managed cases with assignment and aging.
- **Merchant**: hierarchy + agreement — **after** auditing MMS for what is already built.

**Track D — Housekeeping (do now, they are cheap)**

- Resolve the orphaned Party registry: finish the port or drop the migrations.
- Report the handbook index drift (`README.md`, `DOC-100`) back to the architecture team.
- Fold this document's per-domain table into `docs/cms/core-domain-new-docs.md` §11, or supersede §11 with a pointer here — §11 currently covers only 8 of 30 domains and will otherwise drift.

---

## Appendix — Koṣa domain → vmu_core module index

| Koṣa | vmu_core |
|---|---|
| 101 Identity | `asm/` |
| 102 Customer | `shared/customer`, `cms/arrangements`, *(orphaned `parties` tables)* |
| 103 / 117 Merchant | `mbs/`, `lms/group`, `lms/merchant_settlement` · *also MMS, external* |
| 104 / 118 Product | `shared/parameter_engine`, `shared/module_config_*`, `cms/plan_segment`, `cms/wallet_product` |
| 105 Arrangement | `cms/arrangement`, `cms/arrangements` |
| 106 Financial Account | `cms/account`, `debit_account`, `prepaid_account`, `wallet_account`, `balance_bucket`, `fx_engine` |
| 107 Transaction | `trams/` |
| 108 Authorization | `fas/` |
| 109 Posting | `cms/internal_gl_poster`, `purchase_posting`, `ledger_entry` · `fas/settlement_posting_adapter` · `its/` · `col/write_off_processor` · `lms/gl_provisioner` · `trams/adjustment_command` |
| 110 General Ledger | `fas/gl/` |
| 111 Clearing | `trams/mastercard_ipm`, `visa_base_ii`, `ipm_pipeline`, `matching_engine`, `clearing_record` |
| 112 Settlement | `lms/merchant_settlement`, `hcs/payment_sweep`, `fas/settlement_posting_adapter` |
| 113 Billing | `cms/statement_generator`, `payment*`, `autopay`, `emi_schedule` |
| 114 Pricing | — *(`mbs/mdr_engine`)* |
| 115 Fee | `cms/fee_engine`, `fee_waiver`, `its/fee_claim*` |
| 116 Interest | `cms/interest_engine`, `penalty_apr_manager` |
| 119 Limits | `cms/temp_limit`, `wallet_velocity_limits` · `hcs/limit_controller`, `spending_control` · `cdm/limit_allocator` |
| 120 Fraud | `fas/risk_adapter`, `risk_feed_subscriber`, `hot_card_cache` |
| 121 Risk | `cdm/`, `kyc/risk_screening` |
| 122 Treasury | — |
| 123 Reconciliation | `trams/reconciliation`, `fas/gl/gl_reconciliation` |
| 124 Dispute | `dps/` |
| 125 Chargeback | `dps/`, `trams/dispute_bridge` |
| 126 Loyalty | `lms/` |
| 127 Notification | `cms/notification*` |
| 128 Reporting | `col/collections_mi`, `hcs/fleet_report`, `fas/gl/trial_balance`, `cms/metro2_generator` |
| Tax | — |
