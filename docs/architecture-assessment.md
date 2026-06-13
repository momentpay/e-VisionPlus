# vMu_core — Architecture Assessment & Reusability Map
*Generated after reviewing VisionMu.md, vmu_core current state, and all five source domains.*

---

## 1. What You Have Now vs. What vMu Needs

VisionPlus has **11 distinct modules**. VisionMu.md initially planned 7. The full module map is:

| VisionPlus Module | Full Name | vMu App | Existing Source | Status |
|---|---|---|---|---|
| FAS | Financial Authorization System | `vMu_fas` | `muNSwitch / da_product_app` | ⚠️ ~85% source reusable |
| CMS | Credit Management System | `vMu_cms` | `wallet_cards` + `wallet_gl` (partial) | ⚠️ ~50% source reusable |
| TRAMS | Transaction Management System | `vMu_trams` | `settlement_core` | ⚠️ ~70% source reusable |
| CDM | Credit Decision Module | `vMu_cdm` | `mw_risk` (partial) | ⚠️ ~60% source reusable |
| ASM | Access Security Module | `vMu_asm` | None | ❌ Net new (operator portal) |
| MBS | Merchant Billing System | `vMu_mbs` | None | ❌ Net new |
| **ITS** | **Integrated Telephony System** | **`vMu_its`** | **None** | ❌ **Missing from original plan** |
| **CTA** | **Card Transaction Administration** | **`vMu_cta`** | **None** | ❌ **Missing from original plan** |
| **CIF** | **Customer Information File** | **`vMu_shared`** | **None** | ❌ **Missing from original plan** |
| **COL** | **Collections & Recovery** | **`vMu_col`** | **None** | ❌ **Missing from original plan** |
| **DPS** | **Dispute Processing System** | **`vMu_dps`** | **None** | ❌ **Missing from original plan** |
| Shared | Parameter engine, ETS cache, schemas | `vMu_shared` | `vmu_core` | ✅ **DONE** |

### Target umbrella structure (revised):
```
vMu_core/
├── apps/
│   ├── vMu_shared/    ← Parameter engine, ETS, schemas, CIF entity
│   ├── vMu_fas/       ← Real-time authorization switch
│   ├── vMu_cms/       ← Credit ledger, EOD, statements, interest
│   ├── vMu_trams/     ← Clearing, settlement, interchange
│   ├── vMu_cdm/       ← Risk, fraud, underwriting
│   ├── vMu_asm/       ← Bank operator portal (LiveView + FAPI 2.0)
│   ├── vMu_mbs/       ← Merchant billing, terminal management
│   ├── vMu_its/       ← IVR/phone cardholder self-service channel
│   ├── vMu_cta/       ← Card stock, bureau interface, personalization
│   ├── vMu_col/       ← Collections, delinquency, write-off, recovery
│   └── vMu_dps/       ← Dispute workflow, chargeback, representment
```

---

## 2. Current vmu_core State

### What is built and compiles clean:
- `VmuCore.Repo` — PostgreSQL Ecto repo
- `VmuCore.Shared.ParameterEngine` — GenServer + ETS with 4-level cascade (Block→Logo→Bank→System) including BIN resolution via `resolve_bin/1`. **This is production-quality.**
- Four Ecto schemas: `SysParameter`, `BankParameter`, `LogoParameter`, `BlockParameter`
- Migration creating all four tables with FK constraints
- Supervision tree: `Repo → ParameterEngine` (ordered correctly)
- `mix.exs` already references all five source repos as path deps — smart foundation

### Critical structural observation:
`vmu_core` is currently a **standalone app that imports path deps**, not a true Elixir Umbrella. The VisionMu.md spec calls for an umbrella. Two valid paths forward:

**Option A — Convert to proper Umbrella** (`mix new vmu_core --umbrella`): Clean separation, each sub-app has its own `mix.exs`, true independent deployment. More setup work now.

**Option B — Keep hub-and-spoke (recommended for now)**: `vmu_core` remains the hub pulling in existing apps as path deps. Wrap/alias their namespaces into vMu-prefixed contexts. Refactor to umbrella in Phase 2 when boundaries stabilize.

**Recommendation: Option B.** Converting to an umbrella mid-stream while also doing domain translation will slow delivery. The current `mix.exs` path-dep approach already gives you compilation isolation.

---

## 3. Domain-by-Domain Reusability Assessment

### 3.1 muNSwitch → vMu_fas (Reusability: 85% — Near Ready)

**What exists:** A genuinely production-capable ISO 8583 switch with:
- `AsyncCorrelator` architecture (GenServer-based STAN correlation with timeouts, monitors, supervisors) — directly equivalent to jPOS QMux
- `Mercury ISO8583` packager stack: ISOMsg struct, bitmap handling, ASCII/BCD/Binary/EBCDIC prefixers — multi-dialect support for Visa, Mastercard, domestic schemes
- `Switch.Router` with dual-format support (ISOMsg + legacy map), NetworkManager integration, error response generation per ISO response codes
- `Switch.Protocol` + `EnhancedProtocol` — Ranch-based TCP listener with message framing (length-prefixed)
- `DeviceListenerSupervisor` + `EnhancedDeviceListenerSupervisor` — dynamic supervisor for connections
- `UpstreamConnectionManager`, `UpstreamRouter`, `UpstreamHealthMonitor` — upstream network pool
- Full event-driven pipeline: `EventDispatcher`, `ResponsePreparationListener`
- Mastercard MPGS integration: API client, OAuth, session manager, payment processor
- YSP processor with packet framing (local switching partner)
- Telemetry: Prometheus exporter, `SwitchMetrics`, `ReversalMetrics`
- Reversal orchestrator with cleanup worker
- SoftHSM integration documented and planned

**Gaps for vMu_fas:**
1. `ParameterEngine.resolve_bin/1` is not yet wired into the routing path — the router currently routes by PAN prefix pattern matching in code, not by ETS BIN table. This must be connected.
2. No `AccountStateCoordinator` (Horde GenServer per account) yet — the switch does not call a CMS process for OTB/limit validation. Currently routes upstream; needs to add an **issuer processing** branch.
3. Mastercard CIS-specific field specs (DE48 subfields, BCD bitmap variant for CIS) need validation against actual CIS spec documents.
4. Stand-in processing (STIP) is documented in VisionMu.md but not implemented — fallback logic when CMS is unavailable.

**Action items for vMu_fas:**
```
Wire: Switch.Router → ParameterEngine.resolve_bin/1 → AccountStateCoordinator
Add: STIP threshold tables in vMu_shared for offline fallback
Validate: CIS packager against actual Mastercard CIS spec
Namespace: Alias DaProductApp → VmuFas in the vmu_core context boundary
```

---

### 3.2 settlement_core → vMu_trams (Reusability: 70% — Good Base, Domain Shift Needed)

**What exists:**
- `CoreTransaction` schema — richly denormalized with full settlement lifecycle: `unmatched → matched → risk_hold → approved → paid`, exception holds
- Full MDR/interchange engine: `InterchangeRate`, `MdrRate`, `MccMdrRate`, `MdrTemplate` — fee calculation is solid
- BIN table routing, chargeback case management
- Alipay Plus integration (SFTP retrieval + CSV parser + Oban jobs) — shows Broadway/Oban pattern
- Bank payout transmitter (SFTP outbound)
- EOD file generator, exception release processor
- `CoreTransactionSync` — authorization-to-settlement matching

**Gaps for vMu_trams:**
1. Current implementation is UAE-domestic acquirer focused (POS/QR). Vision Plus needs **issuer-side** settlement — processing Mastercard IPM and Visa Base II inbound clearing files, not outbound acquiring batches.
2. No IPM file parser (Mastercard's binary fixed-width clearing format) — this is materially different from the CSV/SFTP pattern currently used.
3. No Visa Base II parser.
4. The `CoreTransaction` schema maps well but needs `clearing_record_type`, `message_reason_code`, `network_reference_number` fields for issuer reconciliation.
5. Broadway pipeline structure exists conceptually (Oban jobs), but for high-volume IPM processing a dedicated `Broadway` producer/processor is more appropriate.

**Action items for vMu_trams:**
```
Build: MastercardIPM.FileProducer (Broadway custom producer for binary IPM format)
Build: VisaBaseII.FileParser  
Extend: CoreTransaction schema with issuer-side fields
Reuse: InterchangeRate, MDR, chargeback, exception processing — directly applicable
Reuse: SFTP client pattern from alipay_plus for inbound file retrieval
Map: settlement lifecycle to vMu GL posting trigger chain
```

---

### 3.3 wallet_cards → vMu_cms Card Layer (Reusability: 50% — Debit Model, Needs Credit Extension)

**What exists:**
- Event-sourced CQRS card entity (`WalletCards.Card`) with status machine: `:active`, `:frozen`, `:blocked`, `:expired`
- Command/event pattern: 11 command modules, corresponding event structs
- Commands: block, freeze, unblock, unfreeze, request_virtual, set_limits, reset_pin, link/unlink external, sync_balance, reconcile_drift
- `BinValidator`, `CardTokenizer`, `CardStore`, `LinkedCardStore`, `CardBalanceSyncStore`
- `Card` struct with `daily_limit`, `monthly_limit`, `is_virtual`, `network`

**Critical gap — this is a debit/prepaid wallet model, not a credit card CMS.** It is missing everything that defines VisionPlus:
- No `credit_limit`, `open_to_buy`, `delinquency_bucket`, `cycle_code`
- No balance buckets (retail, cash, fees, interest)
- No interest accrual engine
- No billing cycle / statement generation
- No minimum payment calculation
- No payment distribution hierarchy (fees first → cash interest → retail)
- `AccountStateCoordinator` GenServer (per-account process for real-time OTB locking) does not exist

**What is still worth keeping:**
- The command/event pattern and status machine transitions — directly applicable
- `CardTokenizer` — usable for PAN tokenization
- `BinValidator` — reusable
- The freeze/block/unblock lifecycle — maps directly to VisionPlus card action codes

**Action items for vMu_cms:**
```
Extend: Card schema with credit-specific fields (credit_limit, otb, cycle_code, delinquency_bucket)
Build: AccountStateCoordinator (Horde GenServer) — the most critical missing piece
Build: BalanceBucket schema (retail, cash, fee, interest per account)
Build: InterestEngine (ADB calculation, Decimal precision)
Build: EOD pipeline (Oban workflows: lock → accrue → age → bill → unlock → GL flush)
Build: StatementGenerator
Build: RepaymentDistributor (payment hierarchy allocation)
Reuse: Command/event pattern, status transitions, tokenizer, BIN validator
```

---

### 3.4 wallet_gl → vMu_cms GL Layer (Reusability: 40% — External GL Adapter, Needs Internal Ledger)

**What exists:**
- GL posting lifecycle: `created → processed/failed → retried`
- Commands: create, post, process, retry
- Pluggable adapter behaviour (`GlAdapter`) — AFEX GL adapter + test adapter
- Idempotency guard, retry policy (Oban-backed)
- `GLReconciliationJob`, `GLVariance`, `GLReconciliationStore`

**Gap:** `wallet_gl` is designed to **post to an external GL system** (AFEX core banking). VisionPlus needs an **internal double-entry ledger** — every transaction generates debit/credit journal entries within the vMu database, which then get extracted to the bank's core banking system.

**What is still worth keeping:**
- Idempotency guard pattern — critical for GL posting correctness
- Retry policy structure — reusable
- GLVariance / reconciliation concepts — directly applicable for EOD reconciliation
- Adapter behaviour — extend to support internal posting + optional external extraction

**Action items for vMu_cms GL:**
```
Build: cms_ledger_entries table and Ecto schema (double-entry journal: account_id, dr_amount, cr_amount, transaction_code, posting_date)
Build: InternalGlPoster — posts journal entries to cms_ledger_entries (replaces AFEX call)
Build: GlExtractor — generates extract files for core banking (reuse adapter pattern)
Reuse: Idempotency guard, retry policy, reconciliation job structure
Reuse: gl_posting_created/processed/failed event structs (adapt to internal context)
```

---

### 3.5 mw_risk → vMu_cdm (Reusability: 60% — Fraud Engine Reusable, Underwriting Missing)

**What exists:** A sophisticated ML-enhanced fraud detection engine:
- Full pipeline: Sanctions → Gateway → Suppression → FeatureHydrator → Abstraction → ActivationEngine → ML ensemble
- ML stack: MLP neural net + IsolationForest ensemble via Axon (Elixir ML framework)
- `VelocityPipeline` — sliding window transaction velocity via Broadway producer
- `SanctionsChecker` + `SanctionsCache` — OFAC/sanctions screening
- `RuleCache`, `RuleExpression`, `AbstractionRuleCache` — configurable rule engine
- `TravelDetector`, `IpClassifier`
- `SideEffect` dispatch: response elevation, case workflow trigger, notifications
- `Explainer` — model interpretability output
- `FeatureSnapshotCrypto` — tamper-evident audit trail
- Pass-safe pipeline: any error returns `:approve` passthrough, never blocks authorization

**Gap for vMu_cdm:** `mw_risk` is a **transaction fraud monitor**, not a **credit underwriting engine**. VisionPlus CDM handles:
- Credit application processing (income verification, employment status)
- Credit bureau API integration (Equifax, Experian, local central bank)
- Credit limit allocation (income multipliers by tier)
- Behavioral re-scoring (periodic account review)

**What maps directly:**
- `VelocityPipeline` → vMu_fas velocity checking (count/value in sliding window per card)
- `SanctionsChecker` → AML/sanctions at both authorization and account opening
- `RuleCache`/`RuleExpression`/`GatewayRuleEngine` → card authorization rules (MCCs, countries, limits, velocity)
- `ScoringPipeline` → fraud score input to authorization decision
- `SideEffectDispatcher` → alert/case creation when suspicious activity detected

**Action items for vMu_cdm:**
```
Reuse: Full ScoringPipeline, VelocityPipeline, SanctionsChecker, RuleEngine → wire into vMu_fas auth path
Build: ApplicationScorer (credit underwriting rules engine, separate from fraud scoring)
Build: BureauIntegration (async HTTP calls to external credit bureaus)
Build: LimitAllocator (income-based credit limit calculation by tier)
Build: BehavioralRescorer (Oban periodic job — re-evaluate active accounts)
```

---

## 4. Structural Gap: vmu_core is Not Yet an Umbrella

**Current `mix.exs`** pulls all five source repos as path deps into a single standalone app. This works for compilation but creates an issue: you cannot independently deploy `vMu_fas` (the latency-critical switch) from `vMu_cms` (the batch EOD processor).

**Recommended migration path:**

```
Phase 1 (Now): Keep vmu_core as hub, wrap each domain behind a vMu-namespaced
               context module. e.g., VmuCore.FAS delegates to DaProductApp.Switch.

Phase 2 (After boundaries stabilize): Convert to proper umbrella.
  vmu_core/
  ├── apps/
  │   ├── vmu_shared/    ← current vmu_core/lib/vmu_core/shared/* (DONE)
  │   ├── vmu_fas/       ← thin wrapper + AccountStateCoordinator around da_product_app
  │   ├── vmu_cms/       ← new CMS logic + wallet_cards/gl adapters
  │   ├── vmu_trams/     ← new file parsers + settlement_core adapters
  │   ├── vmu_cdm/       ← mw_risk + new underwriting modules
  │   ├── vmu_asm/       ← Phoenix LiveView portal (new)
  │   └── vmu_mbs/       ← merchant acquiring (new)
```

---

## 5. What Is Missing Entirely (Net New Build)

These do not exist in any of the five source repos and must be built from scratch.

### 5A. Within Planned Modules (originally identified gaps)

| Component | Module | Priority | Complexity |
|---|---|---|---|
| `AccountStateCoordinator` GenServer (Horde) | vMu_cms | 🔴 Critical | High |
| Credit balance buckets + Decimal interest engine | vMu_cms | 🔴 Critical | Medium |
| EOD Oban workflow (lock→accrue→age→bill→unlock→GL) | vMu_cms | 🔴 Critical | High |
| Statement generator | vMu_cms | 🟡 High | Medium |
| Mastercard IPM file parser (Broadway) | vMu_trams | 🔴 Critical | High |
| Visa Base II file parser | vMu_trams | 🟡 High | High |
| Internal double-entry GL ledger | vMu_cms | 🔴 Critical | Medium |
| STIP (Stand-In Processing) | vMu_fas | 🟡 High | Medium |
| Credit underwriting rules engine | vMu_cdm | 🟡 High | Medium |
| Credit bureau HTTP integration | vMu_cdm | 🟡 High | Low |
| Phoenix LiveView operator portal + FAPI 2.0 | vMu_asm | 🟢 Medium | High |
| Merchant hierarchy + terminal mgmt | vMu_mbs | 🟢 Medium | Medium |
| Horde cluster setup (distributed registry) | vMu_shared | 🟡 High | Medium |

### 5B. Missing Modules — ITS (Integrated Telephony System)

ITS is the cardholder IVR/phone self-service channel. Every VisionPlus issuer deploys this.

| Component | Description | Priority |
|---|---|---|
| IVR session manager | State machine per IVR call session (auth, menu, action, close) | 🟡 High |
| Balance/limit/transaction inquiry via IVR | Read-only card inquiries over phone | 🟡 High |
| PIN management via IVR | PIN set, change, verify — HSM-backed, no agent sees PIN | 🟡 High |
| Card activation via IVR | Activation code flow — cardholder activates plastic via phone | 🟡 High |
| Card block/report via IVR | Lost/stolen self-reporting without agent | 🟡 High |
| OTP generation and delivery | 2FA OTP for digital channels; TOTP/HOTP engine | 🟡 High |
| Payment scheduling via IVR | Accept phone payment instruction | 🟢 Medium |
| IVR platform adapter | Genesys/Avaya/Asterisk VXML or MRCP adapter | 🟢 Medium |

**Note:** ITS shares the PIN HSM with CTA (issuance) and FAS (authorization-path PIN verify). All three call the same HSM adapter but for different operations.

### 5C. Missing Modules — CTA (Card Transaction Administration)

CTA manages the physical card lifecycle: bureau → vault → cardholder → destruction.

| Component | Description | Priority |
|---|---|---|
| Embossing file generator | Produce personalization file sent to card bureau (PAN, name, expiry, CVC2, track data) | 🔴 Critical |
| Card order management | Order request workflow with bureau; track quantity by BIN/logo | 🔴 Critical |
| Stock inventory manager | Vault/branch inventory: cards on hand, reserved, issued, returned | 🟡 High |
| Card receipt acknowledgement | Receive and reconcile bureau delivery against order | 🟡 High |
| Damaged/returned card processing | Write-off undeliverable cards from inventory | 🟡 High |
| PIN mailer coordination | Separate PIN delivery tracking (PIN mailer vs. card delivery) | 🟡 High |
| Card activation tracker | Is this specific plastic physically activated? (distinct from account status) | 🟡 High |
| Card order status inquiry | Bureau tracking status for pending orders | 🟢 Medium |
| Bureau adapter interface | Pluggable bureau integration (Giesecke+Devrient, Thales, etc.) | 🟢 Medium |

**CTA owns the embossing data pipeline. CMS owns the account. They are related but separate.**

### 5D. Missing Modules — CIF (Customer Information File)

CIF is the customer master that sits above individual card accounts.

| Component | Description | Priority |
|---|---|---|
| Customer entity schema | `cms_customers` table: customer_id, name, DOB, nationality | 🔴 Critical |
| Customer ↔ Account relationship | One customer → many accounts (credit, supplementary, corporate) | 🔴 Critical |
| KYC document storage | ID proof, address proof, supporting docs reference | 🟡 High |
| Customer update workflow | Name/address/contact changes propagated across all linked accounts | 🟡 High |
| Corporate customer registration | Corporate entity → multiple cards with shared limits | 🟡 High |
| Relationship classification | Retail / Business / Corporate / Premium tier | 🟢 Medium |

**Without CIF:** you cannot implement multi-product per customer, corporate programmes, or the `APUPCR` / `ACRREG` YSP-equivalent flows.

### 5E. Missing Modules — COL (Collections & Recovery)

COL takes over from CMS EOD aging when an account enters delinquency.

| Component | Description | Priority |
|---|---|---|
| Collection queue engine | Assign delinquent accounts to collection queues by DPD bucket | 🟡 High |
| Dunning letter generator | Automated written notices at 30/60/90/120 DPD transitions | 🟡 High |
| Workout plan manager | Restructured payment schedules for hardship accounts | 🟡 High |
| Collection agency interface | Bulk handoff file for external agencies at 120+ DPD | 🟡 High |
| Write-off processor | Move balance to charged-off GL bucket; update credit bureau | 🟡 High |
| Recovery tracker | Post-write-off partial repayment tracking | 🟢 Medium |
| Legal referral workflow | Escalation to legal/court for high-value charge-offs | 🟢 Medium |

### 5F. Missing Modules — DPS (Dispute Processing System)

DPS is NOT a UI feature inside ASM. It is an independent time-critical state machine.

| Component | Description | Priority |
|---|---|---|
| Dispute state machine | States: filed → retrieval_requested → chargeback_filed → represented → pre_arb → arbitration → closed | 🟡 High |
| Network deadline scheduler | Oban timed jobs enforcing Visa/MC dispute deadlines (hard cutoffs) | 🟡 High |
| Retrieval request processor | Issue retrieval request to acquirer via network | 🟡 High |
| Chargeback filing engine | Format and submit chargeback to Visa/MC | 🟡 High |
| Representment handler | Process acquirer representment; decide accept/escalate | 🟡 High |
| Provisional credit posting | Issue temporary credit to cardholder during dispute | 🟡 High |
| Pre-arbitration workflow | Second-round dispute before network arbitration | 🟢 Medium |
| Compliance case management | Rule-based disputes independent of cardholder claim | 🟢 Medium |
| Dispute GL reconciliation | Track financial impact of each dispute stage through resolution | 🟢 Medium |

**Deadline note:** Visa mandates chargeback within 120 days of transaction. Representment within 30 days of chargeback. Missing these forfeits the case automatically and the issuer absorbs the loss.

### 5G. Additional Sub-System Gaps (within planned modules)

| Gap | Should Live In | Priority |
|---|---|---|
| HSM PIN subsystem (issuance + auth-path verify) | vMu_cta + vMu_fas | 🔴 Critical |
| 40-parameter velocity matrix (channel × frequency) | vMu_cms schema + vMu_cdm velocity engine | 🔴 Critical |
| FX rate table management (multi-currency) | vMu_cms | 🟡 High |
| Credit bureau reporting (Metro 2 monthly file) | vMu_cms | 🟡 High (regulatory) |
| Cardholder web/mobile portal | vMu_asm (separate from operator portal) | 🟡 High |
| Per-card campaign/override code assignment | vMu_cms + vMu_shared (ETS) | 🟡 High |
| Card service operations (activation, replacement) | vMu_cms card lifecycle | 🟡 High |
| Manual debit/credit adjustment posting | vMu_cms | 🟡 High |

---

## 6. Recommended Build Sequence (Revised — 11 Modules)

### Phase 1: Shared Foundation + FAS Authorization Path (Weeks 1–4)
1. Add `horde` dep to `vmu_core`
2. Build `VmuCore.Shared.Customer` entity (CIF foundation — customer above account)
3. Build `VmuCore.CMS.AccountStateCoordinator` (GenServer + Horde registry)
4. Wire `Switch.Router` → `ParameterEngine.resolve_bin/1` → `AccountStateCoordinator.authorize/3`
5. Implement STIP threshold table in `vmu_shared`
6. Wire `mw_risk` velocity + sanctions into FAS auth path

### Phase 2: CMS Credit Core + CTA Card Issuance (Weeks 5–12)
Card issuance (CTA) and credit ledger (CMS) are built in parallel — they are coupled at card creation.

7. `cms_accounts` + `cms_balance_buckets` + `cms_ledger_entries` migrations
8. Extend `block_parameters` with 40-parameter velocity matrix
9. `InterestEngine` (ADB, Decimal, fee application)
10. EOD Oban workflow (sequential, crash-safe, idempotent)
11. `StatementGenerator` + `RepaymentDistributor`
12. CTA embossing file generator + bureau adapter interface
13. CTA stock inventory manager
14. HSM PIN subsystem (issuance path via CTA; auth-path verify already in FAS/SoftHSM)
15. Card activation workflow (CTA plastic activation → CMS account activation)

### Phase 3: ITS + DPS (Weeks 13–18)
16. IVR session state machine (vMu_its)
17. IVR PIN flows (set/change/verify) — reuse HSM adapter from Phase 2
18. OTP engine (HOTP/TOTP for digital channels)
19. Dispute state machine + Oban deadline scheduler (vMu_dps)
20. Provisional credit posting (DPS → CMS GL integration)

### Phase 4: TRAMS Clearing + COL Collections (Weeks 19–24)
21. Mastercard IPM Broadway pipeline
22. Visa Base II parser
23. Authorization-to-clearing matching engine + GL extract
24. COL collection queue engine + dunning letter generator
25. Write-off processor + recovery tracker

### Phase 5: CDM + ASM + MBS (Weeks 25–30)
26. Credit underwriting rules engine + bureau integration
27. Cardholder web portal (vMu_asm — separate from operator portal)
28. Operator portal LiveView + FAPI 2.0
29. MBS merchant hierarchy + MDR engine
30. Credit bureau reporting (Metro 2 monthly file)

---

## 7. VisionPlus Migration Compatibility Checklist

For existing VisionPlus customers to migrate naturally, confirm these mappings:

| VisionPlus Concept | vMu Implementation | Status |
|---|---|---|
| SYS/BANK/LOGO/BLOCK hierarchy | `ParameterEngine` + 4 schemas | ✅ Done |
| BIN routing table | `ParameterEngine.resolve_bin/1` | ✅ Done |
| Parameter fallback cascade | ETS 4-level lookup | ✅ Done |
| Card status codes (active/frozen/blocked) | `WalletCards.Card` status machine | ✅ Exists (adapt) |
| Cycle code (billing day 1–31) | `cms_accounts.cycle_code` | 🔨 Schema needed |
| Delinquency buckets (0/30/60/90 DPD) | `cms_accounts.delinquency_bucket` | 🔨 Schema needed |
| Balance buckets (retail/cash/fee/interest) | `cms_balance_buckets` | 🔨 Schema needed |
| ISO 8583 MTI 0100/0110 auth | `DaProductApp.Switch` | ✅ Exists |
| ISO 8583 MTI 0400/0410 reversal | `ReversalOrchestrator` | ✅ Exists |
| ISO 8583 MTI 0800/0810 network mgmt | `Switch.Protocol` | ✅ Exists |
| Mastercard CIS packager | Mercury BCD packager (validate) | ⚠️ Needs CIS validation |
| GL journal entries (debit/credit) | Internal GL poster | 🔨 Build needed |
| Settlement file (IPM/Base II) | IPM/Base II parser | 🔨 Build needed |
| Interchange fee tables | `InterchangeRate` + `MdrTemplate` | ✅ Exists (adapt) |
| Velocity rules | `mw_risk VelocityPipeline` | ✅ Exists (wire in) |
| AML/Sanctions | `MwRisk.SanctionsChecker` | ✅ Exists (wire in) |
| HSM PIN validation | SoftHSM integration (documented) | 🔨 Implementation needed |
