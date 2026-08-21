# New Card Products — UI & Operational Management Plan

**Status:** 📝 For review (2026-07-12) — development does not start until this
plan is signed off. Companion to the six product planning docs
(`docs/{debit,prepaid,wps,fleet,bnpl,wallet}/`) and the split decision
recorded 2026-07-11/12: Prepaid/WPS/BNPL/Debit → wallet-app, Fleet/Virtual
Cards → vmu_core, scheme tokenization → separate track.

Everything below is grounded in direct inspection of both codebases, not
assumption — file paths cited throughout.

---

## 1. What Exists Today (verified inventory)

### vmu_core admin console (`/visionplus/admin`)
- **One console, ops-only** (no customer-facing UI — cardholders are served
  via IVR/future channels, not a vmu_core web portal).
- **Identity/authz:** ASM — PBKDF2 operator accounts, 7 roles, 51-grant
  role×module×action matrix, action-level gating on every screen, PII
  masking by role, maker-checker with authority limits, unified Approval
  Inbox, searchable audit trail with retention sweep (ASM-P1..P7, all
  verified).
- **Per-module components** registered in `AdminLive` (sidebar + dispatch):
  customer, account (incl. CTA card lifecycle tab), COL, operators,
  approval inbox, audit log, module configuration, etc.
- **Established pattern for adding a module UI** (used by COL-P5, CTA-P3):
  component + `AdminLive` registration + `RolePermission` grants + LiveView
  tests.

### wallet-app UI (two portals + one merchant surface)
- **Customer portal `/app/*`** — 30 LiveViews: dashboard, transfer,
  bill-payment, transactions, statements, beneficiaries, KYC, cards
  (freeze/unfreeze/PIN/virtual/link), loans (+calculator), insurance,
  rewards/offers, disputes, QR receive/request-money, sub-wallets,
  wallet-products, merchant portal screens.
- **Admin console `/admin/*`** — 30+ LiveViews: user search/detail/
  management, transaction inquiry, card search, cash-out requests, disputes
  admin, KYC cases, AML alerts, SAR records, exceptions, loan admin,
  insurance admin, merchant admin, rewards management, wallet products
  admin, withdraw requests, role/permission management, policies, audit
  log, SLO dashboard, incidents, health checks, DR checkpoints, tenant
  config, service controls, report builder.
- **Identity/authz:** separate from ASM — `AdminAuth` session +
  JWT claims, 7 roles (customer/customer_business/ops_agent/ops_supervisor/
  compliance_officer/sre/admin), ABAC policy engine (40+ actions, MFA +
  ownership guards), `RequireRole`/`EnforcePolicy` plugs.
- **`wallet_disputes`** — real dispute system: `Dispute`, `RefundRequest`,
  `SlaPolicy`/`SlaMonitor`/`SlaEscalationAlert`, customer + admin LiveViews.
- **Confirmed absent:** any WPS UI (backend `wallet_wps` is real; zero
  screens reference it).

### The structural difference that drives this plan
vmu_core is an **ops-console-only** system (back office for a card
platform). wallet-app is a **full three-sided product** (customer + ops +
merchant). The new products split across that line, so UI placement follows
the data — but operational management needs explicit cross-system answers,
which §2 gives.

---

## 2. Cross-Cutting Decisions (apply to every product)

### D1 — UI follows the data. No cross-embedding in v1.
A product's screens live in the repo that owns its data. No iframe/API
embedding of wallet-app screens into vmu_core admin or vice versa in v1 —
that would couple two independently-deployed UIs for cosmetic benefit.
Cost accepted: ops staff covering both credit and balance products use two
consoles. Mitigation: §2 D2 (identity convergence) and §5 (support routing
matrix so staff always know which console serves which scenario).

### D2 — Two logins now; one IdP later. Convergence point already exists.
ASM operators and wallet-app admins are separate identity systems today.
Do **not** build a bespoke bridge. The convergence path is already designed
on both sides: ASM's `authn_source` config key (SSO/AD/LDAP — exists,
deliberately unwired, ASM-P6) and wallet-app's JWT-claims-based `AdminAuth`.
When corporate SSO/IdP is introduced (a business decision, not scoped
here), both consoles authenticate against it and "two logins" becomes "one
login, two bookmarks." Until then: ops staff are provisioned in whichever
console(s) their product responsibility requires, with role parity
documented per product below.

### D3 — Two audit trails, one correlation convention.
vmu_core audits to `cms_operator_audit` (searchable UI, retention sweep);
wallet-app audits via `AuditEvent` + audit log admin screen. Keep both —
merging them is high-cost/low-value. **New convention (small, do in every
product's phase 1):** any operation that spans both systems (e.g., FAS
authorizes → wallet_ledger holds) carries one correlation id
(STAN/RRN-derived) recorded in both trails, so a compliance search in
either console can find its counterpart in the other.

### D4 — Cross-system reconciliation is a first-class ops surface, not a
script. (New shared workstream — prerequisite for Debit/Prepaid go-live.)
Once FAS authorizes against `wallet_ledger`, money truth spans two
databases (Postgres holds/clearing vs MySQL balance ledger) with no shared
transaction. Required before any balance product goes live:
- **Switch-side:** extend TRAMS's existing recon to include wallet-routed
  BINs (auths, completions, reversals per day per BIN range).
- **Wallet-side:** `wallet_settlement.RunReconciliation` (exists) extended
  to consume the switch-side extract.
- **One daily cross-check report** — holds placed vs holds settled/expired,
  ledger deltas vs cleared amounts — surfaced in **both** consoles
  (vmu_core: new panel; wallet-app: existing reports/exceptions screens),
  because a break can be worked from either side.
- **Orphan-hold sweep** — auth holds in `wallet_ledger` never matched by a
  completion/reversal must auto-expire (mirror of vmu_core's existing
  `fas_pending_holds` expiry) with exceptions queued, not silently dropped.

### D5 — Maker-checker parity for financial ops in wallet-app.
vmu_core has centralized maker-checker with authority limits (ASM-P3).
wallet-app has role gating + MFA guards but no equivalent 4-eyes engine.
Any new **financial** admin action added by these products in wallet-app
(manual balance adjustment, WPS exception refund, BNPL write-off) must get
a pending→approve flow with maker≠checker — implemented once as a small
shared wallet-app pattern in the first product that needs it (WPS), reused
by the rest. Not retrofitting wallet-app's existing screens; new actions only.

### D6 — EOD/batch independence with one sequencing rule.
vmu_core EOD (CMS jobs, Oban) and wallet-app jobs stay independent. Single
rule: the D4 cross-check report runs after both sides' daily cycles
complete. No cross-system job orchestration engine in v1.

### D7 — Customer & KYC: one Party, per-product KYC, configurable identifiers.
(Added 2026-07-12 in response to the product owner's customer-information
concern; **revised same day** after product-owner review: banks require
product-specific KYC — flows, tiers, and refresh differ per product — and
the match identifier must be configurable per country/bank (Aadhaar/PAN/
phone for India, Emirates ID for UAE, etc.). This revision supersedes the
first draft's simpler "linkage registry" with the full party/KYC model.
This is the highest-consequence decision in this document.)

**The problem, stated precisely.** With the product split, one human being
can exist as **two unlinked customer records in two databases**:
`cms_customers` in vmu_core Postgres (credit CIF — full KYC,
individual/corporate) and wallet-app's `users` + KYC cases in MySQL
(self-service onboarding, its own 5-state KYC workflow). Without a
deliberate mechanism this produces, concretely:

1. **Dual KYC** — the same person KYC'd twice, at double cost, with
   possibly different outcomes (VERIFIED in one, PENDING in the other).
2. **PII drift** — address/mobile updated in one system, stale in the
   other; statements and OTPs go to the wrong place.
3. **Regulatory single-customer-view failure** — AML rules (CBUAE and
   equivalents) require seeing a customer's *whole* relationship;
   a SAR filed in wallet-app is invisible to vmu_core COL/CDM and vice
   versa.
4. **Compliance-flag blindness** — a customer marked deceased/blacklisted/
   sanctioned in one system keeps transacting in the other. (Aggravated by
   a known vmu_core gap: CIF FR-008's customer status field
   ACTIVE/DECEASED/BLACKLISTED **doesn't exist yet** — flagged in the
   2026-07-11 CIF review.)
5. **Exposure blind spot** — `CMS.CustomerExposure` (credit) knows nothing
   of wallet balances/BNPL loans; total-relationship credit decisions and
   collections both under-see the customer.
6. **Right-to-erasure/retention spanning two stores** — a GDPR-style
   erasure request must be orchestrated across both or it's non-compliant.

**The model — four concepts that "customer" currently conflates, separated:**

```
Party (ONE golden identity record per human/entity)
 ├── PartyIdentifiers (MANY — typed, configurable per country/bank)
 ├── ProductRelationships (MANY — one per product enrollment,
 │     pointing at the product system's local record)
 │      └── KycRecord (ONE PER RELATIONSHIP — own flow, own tier,
 │            own documents, own expiry/refresh cycle)
 └── PartyFlags (deceased / blacklist / sanction / legal-hold —
       party-level, propagate everywhere)
```

The product-owner requirement — *fresh, product-specific KYC per product* —
is architecturally correct and is the standard issuer pattern: **KYC is
relationship-scoped due diligence, not a person-scoped flag.** A prepaid
gift card, a credit card, and a corporate fleet facility legitimately have
different KYC tiers, flows (eKYC/video/in-person), document sets, and
refresh cycles, per market. Each product runs its own KYC flow and keeps
its own KYC record. The one refinement over the raw proposal: the
*identity* (name, DOB, the person themselves) is **not** duplicated per
product — that would recreate PII-drift problem #2 above. Identity lives
once at the Party level; everything product-specific hangs off the
relationship.

**Configurable identifiers (the "one identifier per country" requirement,
hardened):** a `party_identifiers` collection — `id_type`, `id_value`
(hashed for match + encrypted at rest), `country`, `verified?`,
`is_primary` — with the **identifier scheme configurable per SYS/BANK via
the Module Configuration Framework**, e.g. India: PAN primary (mandatory
for credit products) + Aadhaar reference (usage legally restricted to
specific eKYC modes — never store the raw number) + phone as *secondary
only*; UAE: Emirates ID primary + passport secondary. Two hard rules from
issuer practice: **phone numbers are never a sole match key** (recycled/
shared), and **fuzzy matches (name+DOB) never auto-merge** — they queue
for manual review. This closes CIF FR-003 (multiple identity documents —
currently single embedded fields) and FR-017 (dedupe — `find_duplicates/1`
becomes the first deterministic matcher) in the same build.

**Where it lives:** a Party Registry inside vmu_core as a **separate
`party_*` schema — deliberately NOT `cms_customers`** — API-fronted by
workstream A1, designed for later extraction into its own service if scale
demands. `cms_customers` (credit) and wallet-app `users` each gain a
`party_id` reference; neither is rewritten.

**KYC recognition as configuration, not code:** each completed product KYC
reports an *attainment* (tier, flow used, attained_at, expires_at) to the
registry. Whether product X may accept an attainment from product Y is a
config rule per product×market: the default is **"always fresh KYC per
product"** (the product owner's stated bank expectation), with per-bank
opt-in recognition rules ("accept tier ≥ FULL attained < 24 months ago")
where a regulator permits — same configurability philosophy as every other
policy decision in this program.

**External KYC providers as pluggable adapters per market** (same adapter
pattern as `FAS.HSM` / `DPS.EvidenceStore`): India CKYC/CERSAI
(fetch/report with KIN), Aadhaar eKYC modes, UAE equivalents — market-gated,
stubbed until a real market integration is scoped, never guessed.

**What propagates across the party (event-driven, both directions):**
sanctions/blacklist hits, deceased flag, fraud block, legal hold — via
`PartyFlags`. **Prerequisite:** CIF FR-008's customer status field
(doesn't exist yet — there is currently nothing to propagate *to* on the
vmu_core side). wallet-app's outbox (`wallet_events`) carries its side; a
vmu_core Oban consumer applies, and vice versa. **What does not
propagate:** KYC status (governed by the recognition config above, not
blanket sync) and profile edits (v1 surfaces "differs from linked record"
in both consoles rather than silently overwriting).

**Customer 360, exposure, erasure (unchanged from first draft, now keyed
on party_id):** single-customer view via wallet-app's existing
`UserDetailLive` + TabRegistry with a "Credit Products" tab fed by A1 read
APIs, mirrored as a "Wallet relationship" panel in vmu_core admin;
`CMS.CustomerExposure` extended with a party-level cross-system lookup
(BNPL outstanding counts toward unsecured exposure — feeds CDM FR-016);
right-to-erasure orchestrated across both stores through the party links.

**Sanctions screening note:** the pending mw_risk sanctions contract
(`docs/cdm/CDM_MwRisk_Sanctions_Integration_Contract.md`) should be scoped
as the **shared** screening engine — one list, one screening path, called
per-party at every product onboarding — rather than wallet-app growing a
second mechanism.

**Revised A3 workstream phases:**
| Phase | Scope |
|---|---|
| A3.1 | Party Registry schema (`parties`, `party_identifiers`, `party_product_links`, `party_kyc_attainments`, `party_flags`) + deterministic matching + probable-match review queue + A1 API endpoints |
| A3.2 | Backfill: link existing `cms_customers` and wallet users into parties (deterministic matches auto-link; fuzzy to the review queue) |
| A3.3 | CIF FR-008 status field + flag propagation (both directions) |
| A3.4 | KYC attainment reporting + recognition config rules |
| A3.5 | External KYC provider adapters (market-gated; India CKYC first if India is the launch market) |

**v2 target (unchanged in spirit):** the Party Registry *is already* the
single identity master from day one — v2 is only about product systems
progressively shedding duplicated identity attributes (wallet users shrink
to auth + party_id; `cms_customers` sheds identity fields into the
registry), using the party links as the migration ledger. No re-platforming
event required.

---

## 3. Per-Product UI & Operations Plans

Ordering within each: customer surface → ops surface → operational
scenarios (the "what happens when it goes wrong" catalog) → phases.
Phases here EXTEND the build phases in each product's own planning doc —
they don't replace them.

---

### 3.1 WPS (wallet-app) — recommended first: backend exists, UI is the gap

**Customer/worker surface** (mostly exists): balance + transactions via
existing `/app` screens once the worker has a wallet account. Add: salary
credit line-items showing employer name + pay period (data already on
`SalaryCredit`).

**Ops surface (net-new — the core of this product's remaining work):**
| Screen | Purpose |
|---|---|
| WPS file upload | Upload + format selection (CSV/fixed-width per `WpsParser`), **pre-flight validation report** (parse errors, control totals, duplicate `payment_reference` warnings) shown BEFORE posting is enabled |
| Batch status | Per-file: total/posted/skipped/failed (the `BatchPostSalaryCredits` summary, live), with idempotent **Re-run** button (backend already safe to re-run) |
| Exception queue | `SalaryCreditExceptionQueue` worked from a screen: view reason, fix (e.g. onboard missing beneficiary), retry single credit, or refund-to-employer (this action gets the D5 maker-checker flow) |
| Employer roster | Employer entity + worker list management (v1: ops-maintained) |
| Regulator report | Generate per-cycle compliance extract; transmission mechanism per the WPS doc's open question 3 |

**Operational scenarios to handle explicitly:**
1. **Partial batch failure** — idempotent re-run posts only the failures;
   UI must show "skipped (already posted)" distinctly from "posted now" so
   ops doesn't misread a re-run as double-payment.
2. **Employee not found** — exception → ops onboards worker → retry from
   queue. SLA-tracked (workers not paid = regulatory exposure).
3. **Duplicate file upload** — `payment_reference` idempotency absorbs it;
   UI shows 100% skipped + a "this file appears already processed" banner.
4. **Employer funding shortfall** — pre-flight compares file net total vs
   employer float balance; posting blocked (not partially run) until funded.
5. **Regulator deadline breach risk** — dashboard tile: files received vs
   posted vs reported, with age; feeds wallet-app's existing SLO screen.
6. **Wrong-amount recall** — employer requests clawback after posting: v1
   policy decision needed (debit worker wallet with consent? exception-only
   manual process?) — flagged as review question, not silently designed.

**Phases:** W-UI1 upload+pre-flight+batch status → W-UI2 exception queue +
maker-checker pattern (D5) → W-UI3 employer roster → W-UI4 regulator
report + SLA tile. (Runs after the product doc's W1/W2 account-model
prerequisite — which Prepaid's build satisfies.)

---

### 3.2 Prepaid (wallet-app)

**Customer surface** (mostly exists): `/app/cards` (freeze/PIN/virtual),
transactions, statements. Add: **load money** flow (reuse transfer/
bill-payment UX patterns), balance+expiry display, KYC step-up prompt when
a load would breach the anonymous-tier cap.

**Ops surface:**
| Screen | Purpose |
|---|---|
| Program management | Create/configure prepaid programs (limits per KYC tier, expiry/dormancy rules) — fits wallet-app's existing `wallet_products_admin_live` pattern |
| Load-channel monitor | Loads by channel/status; failed-load exception queue |
| Manual adjustment | Credit/debit correction with D5 maker-checker |
| Expiry/dormancy dashboard | Upcoming expirations, dormancy fees applied, escheatment candidates |

**Operational scenarios:**
1. **Failed load** (money left the funding source, wallet not credited) —
   exception queue + provider recon (load-channel recon file vs
   `wallet_ledger` credits daily).
2. **KYC-tier cap breach attempt** — load rejected with step-up path;
   compliance visibility via existing AML alerts screen.
3. **Refund-to-source / cash-out at card end-of-life** — uses existing
   `cash_out_live` admin flow, extended for prepaid closure.
4. **Negative balance** (force-posted clearing item exceeding balance) —
   same policy question as Debit scenario 1; answer once, apply to both.
5. **Expiry of value** — sweep job + pre-expiry notification via
   `wallet_notifications`; ops report of expired-value P&L.

**Phases:** P-UI1 program mgmt + load flow → P-UI2 load recon + exception
queue → P-UI3 expiry/dormancy dashboards → P-UI4 KYC step-up UX.

---

### 3.3 Debit (wallet-app) — gated on the FAS integration workstream

**Customer surface** (mostly exists): cards, transactions, statements.
Add: linked-funding view if a real deposit account sits behind it.

**Ops surface:** account funding view, overdraft management (if in scope),
**auth-hold monitor** (holds placed by FAS via `WalletLedger.authorize_debit`
— age, orphan status, manual release with maker-checker).

**Operational scenarios (the FAS-integration ones live here because Debit
is the first product on that path):**
1. **Force-post / offline clearing with no prior auth** — clearing debits a
   possibly-insufficient balance → **negative balance policy** (allow +
   collect? decline into exception? small-amount write-off threshold?).
   This is THE debit-specific policy decision; must be answered in review.
2. **Orphan holds** — D4 sweep + exception queue.
3. **ATM disputes** — route into `wallet_disputes` (exists, has SLA
   monitoring) — NOT vmu_core DPS, which is credit/scheme-cycle shaped.
   Scheme-level chargeback filing for debit still goes via the switch;
   define the handoff: wallet dispute case ↔ Mastercom filing (reuse
   DPS-P5's `MastercomClient`, which is product-agnostic).
4. **Cross-system recon break** — worked from the D4 report.
5. **Reversal storm** (merchant batch reversal) — `reverse_posting` is
   idempotent; ops needs a bulk view, not one-by-one.

**Phases:** D-UI1 auth-hold monitor + D4 recon surfaces → D-UI2 negative
balance policy implementation + exception queue → D-UI3 dispute handoff →
D-UI4 overdraft (if scoped in).

---

### 3.4 BNPL (wallet-app)

**Customer surface:** repayment schedule + early settlement (extend
existing `/app/loans` + `loan_calculator_live`), instalment reminders via
`wallet_notifications`.

**Merchant surface:** v1 = API-first + ops-mediated onboarding via existing
`merchant_admin_live`; wallet-app already has merchant portal screens
(`merchant_portal_live`, `merchant_settlements_live`) to extend in v2 for
BNPL self-service (settlement view, refund initiation).

**Ops surface:**
| Screen | Purpose |
|---|---|
| Underwriting queue | Manual review of referred per-purchase decisions |
| Loan book | Portfolio view: active/delinquent/settled by merchant/cohort |
| Merchant management | Discount rates, settlement config (extends merchant_admin) |
| Refund/return workbench | The messy one — see scenario 2 |
| Delinquency view | Missed instalments, dunning state, write-off (D5 maker-checker) |

**Operational scenarios:**
1. **Approved but merchant funding failed** — compensation flow; purchase
   must not stand if the merchant was never paid.
2. **Customer returns goods** — merchant refund → unwind remaining
   instalments + refund paid ones; partial returns prorate. This needs an
   explicit state machine in the plan review, not improvisation.
3. **Missed instalment** — BNPL-specific dunning ladder (not COL's DPD
   buckets); notification sequence + retry-collection attempts.
4. **Merchant fraud/abuse** — spike detection per merchant; suspend
   merchant (stops new approvals, doesn't touch existing loans).
5. **Early settlement** — recompute (waive unearned interest if
   interest-bearing model chosen).

**Phases:** B-UI1 underwriting queue + loan book → B-UI2 refund/return
workbench → B-UI3 delinquency + dunning → B-UI4 merchant self-service.
(All following the product doc's B1-B4 backend phases.)

---

### 3.5 Fleet (vmu_core)

**No customer portal** — fleet is B2B; the "customer" is the company's
fleet manager. v1: ops-mediated via vmu_core admin. v2 option: company
self-service (would be vmu_core's first external-facing UI — flagged as a
significant scope decision, not assumed).

**Ops surface (this builds the missing HCS admin UI — closing a flagged
gap — then adds fleet on top):**
| Screen | Purpose |
|---|---|
| Company/facility management | HCS `Company` CRUD, facility limit changes via existing Approval Inbox (maker-checker already wired) |
| Vehicle/driver roster | Fleet sub-accounts, card-to-vehicle assignment + reassignment history |
| Spending controls editor | `SpendingControl` CRUD (MCC lists, caps) — company + card scope |
| Fuel reports | Spend by vehicle/driver/fuel-type; consumption anomalies |
| Anomaly review queue | Flagged transactions (tank-capacity breach, velocity) → investigate/confirm/contact company |

Standard vmu_core pattern: new `fleet` (or extended `hcs`) module in
`AdminLive`, `RolePermission` grants (SUPERVISOR/OPS edit, COMPLIANCE
view), LiveView tests — same as COL-P5.

**Operational scenarios:**
1. **DAILY_CAP + cash-block enforcement** — the two pre-existing HCS gaps
   fixed first (product doc F1); ops needs to see cap-decline reasons in
   the existing decline observability.
2. **Vehicle reassignment** — history preserved (who drove what when —
   companies audit this).
3. **Company suspension** — propagates to all cards (HCS `check_company_active`
   already enforces); ops screen shows blast radius before confirming.
4. **Odometer anomalies** — review queue, not auto-block (data quality at
   fuel pumps is poor; false-positive tolerance needed).
5. **Facility limit breach pressure** — utilization dashboard per company.

**Phases:** F-UI1 HCS base admin (company/employee — closes existing gap)
→ F-UI2 vehicle roster + controls editor → F-UI3 reports + anomaly queue.

---

### 3.6 Virtual Cards (vmu_core) — smallest item

**Ops surface:** extend the existing account Cards tab (CTA-P3): card-type
selector on issue (PRIMARY/SUPPLEMENTARY/**VIRTUAL** — schema already
accepts it), instant-issuance path (state machine already supports issuing
straight to INACTIVE, skipping ORDERED/EMBOSSED/DISPATCHED), immediate
activation option.

**Operational scenarios:**
1. **Virtual → physical upgrade** — issue a physical generation on the same
   account (replacement flow variant, `replaces_card_id` chain preserved).
2. **Credential delivery** — **✅ resolved 2026-07-12, supersedes the v1
   "ops-assisted" placeholder below**: product owner confirmed credential
   delivery must be API-based (consistent with the Q4/Q5 "vmu_core
   provides APIs" direction), delivered to whatever channel calls the API
   (wallet-app, a future app, IVR). This makes API delivery a real
   dependency on workstream **A1**, not a v2 nicety.
3. **CVV re-view policy** — deliberately NOT storing/displaying CVV
   (consistent with existing "raw PAN never stored"); regeneration only.

**Phases — split to unblock the ops-only part immediately:**
- **V-UI1a** (no dependency, can start now): admin-issuance flow only —
  card-type selector, instant-issuance path, ops can view masked
  PAN/status in the existing Cards tab exactly like any other card. Does
  **not** deliver credentials to a cardholder yet.
- **V-UI1b** (depends on A1): `POST /cards/virtual` issuance API +
  one-time-reveal credential endpoint (PAN/CVV/expiry returned once,
  never persisted in retrievable form, audited on access) — the real
  cardholder-facing capability. This is what actually makes virtual cards
  usable, not just issuable.

---

## 4. Scheme Tokenization (separate track — per 2026-07-12 decision)
UI/ops plan deferred until its T1 (scheme selection). Noted for
completeness — the ops surfaces it will eventually need: token lifecycle
dashboard (provisioned devices per card), provisioning-decline review
queue, and hooks already identified into CTA `CardLifecycle`. Nothing else
planned now.

---

## 5. Support Routing Matrix (which console for which scenario)

| Scenario | Console | Screen |
|---|---|---|
| Credit card statement/limit/delinquency query | vmu_core admin | Account component |
| Credit dispute/chargeback | vmu_core admin | DPS (+ Mastercom adapter) |
| Prepaid/debit balance or transaction query | wallet-app admin | User search → detail / Transaction inquiry |
| Prepaid load failed | wallet-app admin | Load exception queue (P-UI2) |
| Debit ATM dispute | wallet-app admin | Disputes admin (existing) |
| WPS worker not paid | wallet-app admin | WPS exception queue (W-UI2) |
| BNPL missed instalment / refund | wallet-app admin | Delinquency view / refund workbench |
| Fleet card declined at pump | vmu_core admin | Fleet controls + decline observability |
| Virtual card issue/upgrade | vmu_core admin | Account Cards tab |
| Cross-system recon break | either | D4 daily report (surfaced in both) |
| Any card block (lost/stolen) — credit or fleet | vmu_core admin | CTA lifecycle actions |
| Any card block — prepaid/debit | wallet-app | Card management (customer) / card search (admin) |

This matrix becomes the ops team's cheat-sheet on day one and the test of
D1's "two consoles" cost: if a single frequent scenario forces console-
hopping mid-task, that's the signal to revisit embedding — measured, not
assumed.

---

## 6. Recommended Sequencing & Review Gates — ✅ Gate 0 passed 2026-07-12

D1–D7 signed off; §7 review questions answered (Q3 BNPL return
state machine still open — does not block early phases). Sequencing below
supersedes the original draft to fold in A1/A2/A3, which the Q4/Q5/D7
answers turned from "later" into real, load-bearing dependencies.

**Two tracks run in parallel from day one** — vmu_core-only work never
waits on wallet-app work or on the foundational workstreams, since none of
it touches a shared dependency yet:

### Track 1 — vmu_core-only, starts immediately, zero cross-system risk
1. **V-UI1a** — virtual card admin-issuance (days).
2. **F1 + F-UI1** — Fleet's two HCS enforcement fixes (`DAILY_CAP`,
   `can_withdraw_cash`) + the missing HCS admin UI. Benefits the *existing*
   corporate card product before any fleet-specific work lands.
3. **F-UI2 / F-UI3** — vehicle roster, controls editor, fuel reports.

### Track 2 — Foundational, unlocks nearly everything else
4. **A1** — vmu_core API layer (auth, versioning, rate limiting). Small
   and abstract on its own, but is now a hard dependency of V-UI1b, D7's
   Party Registry exposure, Fleet v2 self-service, and the Q4/Q5
   architectural direction generally. **Recommend building the *thinnest
   possible* first slice** — one authenticated endpoint, proven end-to-end
   (say, a read-only account lookup) — rather than a speculative full
   framework, then growing it per-consumer.
5. **A3.1** — Party Registry schema + deterministic matching + review
   queue, exposed via A1 as soon as A1's first slice exists. This is the
   direct answer to the customer-information concern that drove D7 — the
   highest business-value item in this whole track.
6. **V-UI1b** — virtual card credential-delivery API, now unblocked by A1.
7. **A3.3** — CIF FR-008 customer status field + flag propagation (needed
   before A3.1's matches are useful for compliance, and before any
   sanctions/deceased/blacklist signal can propagate anywhere).
8. **A2** — SSO/IdP integration. Can start in parallel with A1 (different
   concern) but should land before wallet-app product UIs multiply the
   number of screens one ops team has to log into separately.

### Track 3 — wallet-app products, start once A3.1 exists (so every new
customer gets linked from day one, not backfilled later)
9. **WPS UI (W-UI1..4)** — backend (`wallet_wps`) already exists; fastest
   path to a fully operational product. Needs Prepaid's account model only
   for worker wallet provisioning (coordinate with #10).
10. **Prepaid (P-UI1..4)** — unblocks WPS fully; also the direct precedent
    Debit builds on.
11. **Debit + D4 recon workstream** — the FAS integration and its ops
    surfaces together; the recon report is a go-live gate, not a
    follow-up.
12. **BNPL** — largest net-new; benefits from everything above, including
    A1 (merchant checkout API) and A3 (borrower identity).

Each phase still gets its own review gate before its own dev starts,
consistent with how every prior vmu_core phase has run — Gate 0 covers the
program shape, not a blanket approval to skip per-phase checkpoints.

---

## 7. Open Questions for This Review — ✅ answered by product owner 2026-07-12
(answers inline below; implications recorded in §7.1)

1. **Negative balance policy** (Debit §3.3-1 / Prepaid §3.2-4) — allow +
   collect, decline to exception, or write-off threshold? One answer, two
   products. 
Answer: it has to be configurable as it could be as per the region/country or the bank customer
2. **WPS wrong-amount recall** (§3.1-6) — is post-payment clawback from a
   worker wallet ever permitted, and under what consent/approval?
Answer:There has to be a define process for this, Currently keep flagged for reviews
3. **BNPL return/refund state machine** (§3.4-2) — needs explicit sign-off
   on partial-return proration before B-UI2.
Answer:
4. **Fleet company self-service** (§3.5) — is a v2 external company portal
   in vmu_core's future, or does B2B self-service belong in wallet-app's
   portal stack even for a vmu_core product? (Defers fine; shapes v2.)
Answer: I think, we should keep wallet_app as UI modules and vmu_core will provide the API's
5. **Virtual card credential delivery** (§3.6-2) — acceptable v1 channel?
Answer: Again this has to be also API's .
6. **Ops staffing model** — same team on both consoles (needs D2 SSO
   sooner) or split teams per product family (two logins is a non-issue)?
Answer: SSO 
7. **Maker-checker in wallet-app (D5)** — confirm the "new financial
   actions only" scope, or should existing wallet-app manual adjustments
   be retrofitted too? (Recommend: new actions only in v1.)
Answer: Need align as per current APIs plan

### 7.1 Implications of the answers (recorded 2026-07-12)

- **Q1 (negative balance = configurable)** → implement via the Module
  Configuration Framework equivalent on the wallet-app side (per-bank/
  region key), mirroring how vmu_core handles market-varying policy. Both
  Debit and Prepaid consume the same key.
- **Q2 (WPS clawback)** → stays a flagged, manual-review-only exception in
  v1; a defined process document is a prerequisite for any automated
  clawback. No clawback code in v1.
- **Q3 (BNPL return/refund state machine)** → **still unanswered** — left
  blank in review. B-UI2 remains blocked on this; not a blocker for
  B-UI1 (underwriting queue + loan book).
- **Q4 + Q5 (wallet-app = UI, vmu_core = APIs)** → **this is a new
  architectural direction with a new workstream attached**: vmu_core
  currently has **zero external API surface** (it is an ISO 8583 switch +
  LiveView admin console — no REST/JSON API exists anywhere). Serving
  wallet-app as the customer-facing UI for vmu_core products (fleet
  self-service, virtual card credential delivery, and by extension any
  future credit-product self-service) requires building a **vmu_core API
  layer** — authenticated, versioned, rate-limited — as a prerequisite.
  Registered below as workstream **A1** and referenced by D7.
- **Q6 (SSO)** → D2's "later" becomes "sooner": corporate IdP/SSO moves
  from deferred to a scheduled early workstream, since one team will work
  both consoles. ASM's `authn_source` wiring + wallet-app IdP integration
  become a real, planned item rather than an unwired config key.
- **Q7 (maker-checker scope)** → aligned with the API plan: D5 flows are
  built API-first (approve/reject as API operations), so the same
  maker-checker engine serves both wallet-app screens and future API
  consumers. Scope stays "new financial actions only" in v1.

### 7.2 New workstream register (created by this review)

| # | Workstream | Why | Blocks |
|---|---|---|---|
| A1 | **vmu_core API layer** — authenticated external REST/JSON API (first consumer: wallet-app UI) | Q4/Q5 answers; D7 customer linkage | Fleet self-service v2, virtual-card credential delivery, D7 Customer 360 |
| A2 | **SSO/IdP integration** — ASM `authn_source` wiring + wallet-app AdminAuth against one corporate IdP | Q6 answer | Single-team ops model |
| A3 | **Party Registry + per-product KYC framework (D7, revised)** — one party, configurable identifiers per market, KYC record per product relationship, flag propagation | Customer-information concern + product-owner direction: per-product KYC with configurable national identifier (see D7) | Any customer holding products in both systems; regulatory single-customer view; every new product's onboarding |
