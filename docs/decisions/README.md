# Koṣa — Architecture Decision Register

| | |
|---|---|
| Created | 2026-08-01 |
| Scope | Development-side decisions for the Koṣa platform implementation (`vmu_core`) |
| Prefix | **`VMU-ADR-###`** |

---

## 1. Why this register exists, and why the prefix

Architecture decisions in this codebase were recorded conscientiously — but never registered. Twenty-four ADRs were written across **six independent numbering series**, each started by whichever tracker needed one:

`ADR-A1…A4` (ASM tracker) · `ADR-C1…C6` (CMS gap tracker) · `ADR-T1…T6` (TRAM tracker) · `ADR-CTA1` (CTA tracker) · `ADR-001…003` (FAS tracker) · `ADR-002…005` (core domain model doc)

Two of those collide outright: **FAS `ADR-002`/`ADR-003` and the core-domain doc's `ADR-002`/`ADR-003` are different decisions with the same identifiers.** A third collision was already being worked around in code — `fas/risk_adapter.ex` carries the comment *"not to be confused with mw-core's own ADR-001"*.

The architecture team maintains its own `ADR-001…006` series in the Koṣa Architecture Handbook (DOC-101 §20), which would be a seventh.

**The prefix is the fix.** The two teams work independently by design and the channel between them is one-directional, so merging numbering across them is not achievable and not worth attempting. Namespacing removes the collision without requiring anyone to coordinate. `VMU-ADR-###` means "a decision made by the development side about the implementation."

## 2. What is registered here versus where the text lives

**This register does not duplicate ADR text.** Each existing ADR keeps its authoritative text where it was written — in the tracker whose context makes it comprehensible. The register adds the three things that were missing: a **unique identifier**, a **status**, and a **single place to look**.

New ADRs with no existing home get their own file in this directory.

## 3. Status vocabulary

| Status | Meaning |
|---|---|
| **Accepted** | In force. The implementation follows it |
| **Superseded** | Replaced by a later decision, named in the row |
| **Obsolete** | The premise no longer holds; the decision is void but retained for history |
| **Needs review** | The premise has shifted enough that someone should confirm the decision still stands. Not yet resolved |
| **Proposed** | Written but never confirmed |

---

## 4. The register

### 4.1 Platform & governance

| ID | Decision | Status | Text |
|---|---|---|---|
| **VMU-ADR-001** | **Platform of record is standalone `vmu_core`**, not the merged Avenza umbrella. Port features *into* vmu_core rather than reconciling in place | Accepted (2026-07-23) | [001-platform-of-record.md](001-platform-of-record.md) |
| **VMU-ADR-002** | **The Koṣa Architecture Handbook is advisory**, not normative. Dev publishes as-built docs; architecture maps against them. One-directional channel, no sign-off gate | Accepted (2026-08-01) | [002-handbook-advisory-status.md](002-handbook-advisory-status.md) |
| **VMU-ADR-003** | **Product is Koṣa; the code namespace rename is deferred indefinitely.** Adopt "Koṣa" in documentation and product language only | Accepted (2026-08-01) | [003-naming-and-rename-deferral.md](003-naming-and-rename-deferral.md) |
| **VMU-ADR-005** | **Debit/Prepaid/Wallet balances are liabilities** (2004/2005/2006), cash clearing is 3002, and the 2001/2002/4001 revenue conflicts resolve to the reconciled chart. Accounting treatment **decided**; execution blocked on the core-banking GL export contract and a historical-data plan | Accepted (2026-08-02), execution pending | [005-stored-value-liability-treatment.md](005-stored-value-liability-treatment.md) |
| **VMU-ADR-004** | **External dependency boundaries.** `muNSwitch` (ISO 8583 engine) and `mw-core` (fraud/risk) are **deliberate boundaries and stay as-is**; **wallet-app is retired** and its six dependencies removed; `tmsuat_apps-main` unchanged (`runtime: false`) | Accepted (2026-08-01) | [004-external-dependency-boundaries.md](004-external-dependency-boundaries.md) · migration plan: [`architecture/Wallet_App_Dependency_Migration.md`](../architecture/Wallet_App_Dependency_Migration.md) |

### 4.2 Authorization & switch (was `ADR-001…003`, FAS tracker)

| ID | Was | Decision | Status |
|---|---|---|---|
| **VMU-ADR-010** | FAS ADR-001 | **`mw_risk` integrated by direct Elixir call**, not HTTP — eliminates a network hop on the latency-sensitive auth path | Accepted. *Verified 2026-08-01: `mw_risk` is a live `path:` dependency and `FAS.RiskAdapter` calls `MwRisk.Pipeline.run/2` directly. The ADR's wording says "same umbrella"; the repo is a single app with path deps, so the mechanism holds and the phrasing is imprecise* |
| **VMU-ADR-011** | FAS ADR-002 | GL integration by reusing `wallet_gl` via direct call | **Superseded by VMU-ADR-012** |
| **VMU-ADR-012** | FAS ADR-003 | **Call `VmuCoreGlAdapter.post_entry/2` directly**; do *not* route through `WalletGl.create_posting/5`, whose `GlPostingStore`/`wallet_database` are not in this supervision tree | **Accepted — and permanent, not interim.** The original ADR framed this as a stopgap until "vmu_core and wallet-app are co-deployed in the same OTP release (VisionPlus milestone 2)". **That clause is void.** [VMU-ADR-001](001-platform-of-record.md) reversed the merge topology it assumed: there is no co-deployment milestone, the platform is one `vmu_core`, and posting directly through `VmuCoreGlAdapter` is the end state. The `WalletGl.GlAdapter` behaviour is retained for contract shape only — it implies no future re-routing |

*Text: [`fas/FAS_Implementation_Tracker.md`](../fas/FAS_Implementation_Tracker.md) §ADR Notes*

### 4.3 Transaction & clearing (was `ADR-T1…T6`, TRAM tracker)

| ID | Was | Decision | Status |
|---|---|---|---|
| **VMU-ADR-020** | ADR-T1 | **Pragmatic event sourcing** — `trams_transaction_events` is the append-only source of truth; `trams_transactions.state` is a projection updated in the same DB transaction, row-locked and seq-ordered | Accepted. *The strongest boundary in the codebase; treated as the model to follow* |
| **VMU-ADR-021** | ADR-T2 | **FAS remains untouched as decision engine** — TRAM references `fas_authorization_id`, never duplicates decision data. TRAM hooks are fail-safe and can never affect an authorization response | Accepted |
| **VMU-ADR-022** | ADR-T3 | **Shared GL idempotency key** `"settlement:<approval_code>:<rrn>"` across both posting paths, making double-posting structurally impossible | Accepted |
| **VMU-ADR-023** | ADR-T4 | **No merchant master table** — `merchant_id`/`merchant_name`/`mcc` stored inline on `trams_transactions`, deferred until an issuer-side merchant master exists | Accepted (deferral). *Resolution point is the open MBS scope question — ownership map §5.5* |
| **VMU-ADR-024** | ADR-T5 | **Disputes stay in DPS**; TRAM adds an FK plus a `DisputeBridge` mirroring dispute lifecycle into the TRAM event log | Accepted |
| **VMU-ADR-025** | ADR-T6 | **No PubSub for the FAS→TRAM feed** — direct calls inside async tasks, since both live in the same OTP app. The outbox pattern is deferred to durable cross-service delivery | Accepted (deferral) |

*Text: [`tram/TRAM_Implementation_Tracker.md`](../tram/TRAM_Implementation_Tracker.md) §ADR Notes*

### 4.4 Credit management (was `ADR-C1…C6`, CMS gap tracker)

| ID | Was | Decision | Status |
|---|---|---|---|
| **VMU-ADR-030** | ADR-C1 | **Configuration via the ParameterEngine cascade, not YAML files** — market values → BANK columns, product values → LOGO columns | Accepted. *Note: the cascade has no version or effective-date columns — ownership map §4.3* |
| **VMU-ADR-031** | ADR-C2 | **Penalty APR persists until cured**, not until DPD drops. Two cure grammars; activation in the accrual job, cure evaluation once per cycle | Accepted |
| **VMU-ADR-032** | ADR-C3 | **v1 payment channels = gateway + direct_debit**; further channels are a config change, not a code change | Accepted |
| **VMU-ADR-033** | ADR-C4 | **Single billing currency per account.** No dual-currency statements; multi-currency stays transaction-side (FX at posting) | Accepted. *Wallet products were designed around this rather than reversing it* |
| **VMU-ADR-034** | ADR-C5 | **Bureau format routed per BANK** via `BureauFormatRouter`; unimplemented formats return an explicit error rather than silently defaulting | Accepted |
| **VMU-ADR-035** | ADR-C6 | **Bureau layouts as overridable data** — generators are pure renderers over a spec; any field, segment or delimiter is replaceable by config, because official member specs are gated and compliance fixes must not need a release | Accepted |

*Text: [`cms/CMS_Gap_Implementation_Tracker.md`](../cms/CMS_Gap_Implementation_Tracker.md) §Decisions from the Q&A review*

### 4.5 Cards & identity

| ID | Was | Decision | Status |
|---|---|---|---|
| **VMU-ADR-040** | ADR-CTA1 | **Card entity is additive; the account row stays the hot-path cache.** `cta_cards` is the system of record for plastic lifecycle, while `cms_accounts`' current-card denormals are retained so FAS's hot path is undisturbed | **Needs review.** Partially overtaken: CU-1 repointed the authorization path at `cta_cards`. Whether the denormals are still load-bearing should be confirmed and the ADR updated or superseded |
| **VMU-ADR-050** | ADR-A1 | **Local credentials first** (PBKDF2-SHA256, lockout); SSO/LDAP as an adapter behind the same `ASM.Auth` context | Accepted, and the adapter was subsequently built |
| **VMU-ADR-051** | ADR-A2 | **Session via Phoenix cookie + one LiveView `on_mount` hook**; the login page is the only unauthenticated admin route | Accepted |
| **VMU-ADR-052** | ADR-A3 | **Role→permission matrix as data, not code** — `asm_role_permissions`, checked by a single `ASM.Authz.can?/3` | Accepted |
| **VMU-ADR-053** | ADR-A4 | **Existing 4-eyes flows keep their signatures**; the UI layer substitutes the authenticated operator ID and enforces role authority | Accepted |

*Text: [`cta/CTA_Gap_Implementation_Tracker.md`](../cta/CTA_Gap_Implementation_Tracker.md) · [`asm/ASM_Implementation_Tracker.md`](../asm/ASM_Implementation_Tracker.md)*

### 4.6 Domain model — architecture-authored, adopted here

These originate in the architecture team's core domain model doc, not the development side. They are registered because implementation decisions reference them, and re-numbered because their original identifiers collide with §4.2.

| ID | Was | Decision | Status in the implementation |
|---|---|---|---|
| **VMU-ADR-060** | core-domain ADR-002 | Relationship replaces Contract — business relationships outlive legal contracts | **Not implemented** — Relationship layer deferred (ownership map §5.1) |
| **VMU-ADR-061** | core-domain ADR-003 | Financial Accounts never own Products | **Partially honoured** — the two concerns are merged in one row per product (§5.3) |
| **VMU-ADR-062** | core-domain ADR-004 | Payment Instruments are separate from Products | **Honoured without a new table** — `cta_cards`' polymorphism is this layer (§5.4) |
| **VMU-ADR-063** | core-domain ADR-005 | Arrangement is the primary business aggregate | **Not implemented as stated** — `cms_arrangements` is a thin cross-product index, deliberately (§5.2) |

*Text: [`cms/core-domain-new-docs.md`](../cms/core-domain-new-docs.md) §8*

---

## 5. A seventh series exists in the predecessor umbrella — and the move that was supposed to consolidate it never completed

**Located 2026-08-01.** `Avenza/docs/adr/` holds a full, numbered series of **18 ADRs** (`0001-app-boundaries` … `0018-unified-transaction-pipeline`) covering app boundaries, eventing/outbox, ledger invariants, idempotency and locking, security, observability, partitioning, release strategy, BCDR, testing, UI composition, and the three unified-model decisions referenced by name in this codebase:

| File | Subject |
|---|---|
| `0016-unified-account-model.md` | Loan/Card gain a real `account_id` |
| `0017-unified-card-issuance.md` | Card issuance moved onto `VmuCore.CTA` |
| `0018-unified-transaction-pipeline.md` | Unified Transaction Pipeline (Phase 1a/1b) — note its Phase 1b closed-loop bypass was later retired |

**These are not registered above and are deliberately not renumbered yet**, because their status in *this* codebase is unknown. Per [VMU-ADR-001](001-platform-of-record.md), code changes made in the predecessor umbrella are **not assumed** to have carried over. Each must be verified against current code before being treated as in force.

### 5.1 The consolidation was announced but never happened

`Avenza/docs/README-CANONICAL-DOCS-MOVED.md` (2026-07-22) states that canonical architecture documentation moved to `vmu_core/docs/`, and directs readers to four files:

| Cited path | Present? |
|---|---|
| `vmu_core/docs/README.md` | **No** |
| `vmu_core/docs/decisions/ADR-0001-platform-of-record.md` | **No** |
| `vmu_core/docs/architecture/north-star.md` | **No** |
| `vmu_core/docs/roadmap/program-tracker.md` · `roadmap/reconciliation-from-wallet-app.md` | **No** — `docs/roadmap/` exists and is empty |

The pointer was left behind; the documents never landed. This is the same merge-drift pattern that [VMU-ADR-001](001-platform-of-record.md) was written to stop — and it took the document recording that very decision.

[VMU-ADR-001](001-platform-of-record.md) in this register is therefore a **fresh write of the decision from its surviving evidence**, not a copy of the lost original. If the original is recovered, reconcile rather than assuming this version is complete.

**Consequence for readers:** treat any reference to `docs/README.md`, `docs/architecture/north-star.md`, or `docs/roadmap/*` in older notes as pointing at documents that do not exist in this tree.

## 6. Open questions

| Question | Where it sits |
|---|---|
| **Release strategy for the retained external boundaries.** `muNSwitch` and `mw-core` stay per [VMU-ADR-004](004-external-dependency-boundaries.md), but they remain `path:` dependencies on a sibling working directory — a development convenience, not a release strategy. Undecided, deliberately deferred until it obstructs something | [VMU-ADR-004](004-external-dependency-boundaries.md) §Known limitations |
| **Status of the 18 predecessor ADRs** in `Avenza/docs/adr/` — each needs verifying against current code before being treated as in force | §5 above |

*(The external-ownership question previously listed here was resolved as [VMU-ADR-004](004-external-dependency-boundaries.md) on 2026-08-01.)*

---

## 7. Conventions

- **Number once, never renumber.** Superseded ADRs keep their identifier and gain a status.
- **New decisions get a file here**, using the template in the handbook's DOC-101 §20.4.
- **Existing ADRs stay where they are.** Move text into this directory only when the owning tracker is retired.
- **Update the status column when a premise shifts** — the entire value of this register is that "Needs review" is visible rather than silently false.
