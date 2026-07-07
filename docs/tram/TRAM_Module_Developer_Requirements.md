# TRAM Module — Developer Requirements Document
### Elixir/Phoenix Implementation of the VisionPLUS Transaction Management System (TRAMS)

**Source:** `vmu_core/docs/tram/visionplus_tram_document.docx`
**Prepared for:** Engineering team implementing the Transaction domain of the E-VisionPlus platform

---

## 1. Purpose & Scope

This document translates the TRAM (Transaction Management System) learning/design notes into a structured requirement set for developers building the Transaction domain of E-VisionPlus in Elixir/Phoenix.

TRAMS is the module of VisionPLUS responsible for storing, correlating, and managing the full lifecycle of every card transaction — from authorization through posting, statementing, disputes, chargebacks, and archival. It is **not** a balance ledger (that's CMS) and **not** a decision engine (that's FAS); it is the **system of record for "what happened"** to a transaction.

> **Developer Note:** The source document is a conceptual/architectural walkthrough (written as a learning roadmap), not a full functional spec. It thoroughly covers architecture, data model, transaction identity, and lifecycle/state-machine design (Modules 1–3A), but **does not** contain detailed functional specs for Modules 4–12 (Inquiry screens, Maintenance, detailed Reversal/Adjustment rules, Statement processing internals, Dispute/Chargeback workflow detail, Batch processing, Integration message formats, Troubleshooting playbooks, and the full End-to-End flow). Section 10 of this document flags each of these gaps and links to a dedicated spec file for each, drafted from general VisionPLUS/card-management domain knowledge — developers should validate each against their own VisionPLUS product/domain knowledge, existing BA/SME input, or actual VisionPLUS screen and batch job documentation where available.

### Document Map

| # | File | Covers |
|---|---|---|
| — | *(this file)* | Architecture, data model, transaction identity, lifecycle/state machine (Modules 1–3A) |
| 04 | [04_transaction_inquiry.md](./04_transaction_inquiry.md) | Transaction Inquiry |
| 05 | [05_transaction_maintenance.md](./05_transaction_maintenance.md) | Transaction Maintenance |
| 06 | [06_reversals_adjustments.md](./06_reversals_adjustments.md) | Reversals & Adjustments |
| 07 | [07_statement_transaction_processing.md](./07_statement_transaction_processing.md) | Statement Transaction Processing |
| 08 | [08_chargebacks_disputes.md](./08_chargebacks_disputes.md) | Chargebacks & Disputes |
| 09 | [09_batch_processing.md](./09_batch_processing.md) | Batch Processing |
| 10 | [10_integration_points.md](./10_integration_points.md) | Integration Points |
| 11 | [11_troubleshooting_production_support.md](./11_troubleshooting_production_support.md) | Troubleshooting / Production Support |
| 12 | [12_end_to_end_flow.md](./12_end_to_end_flow.md) | End-to-End Transaction Flow |

All files 04–12 are marked ⚠️ **drafted from general domain knowledge, not extracted from the source docx** — each carries its own Open Questions section for SME/product validation.

---

## 2. Where TRAM Sits in VisionPLUS

| Module | Main Responsibility |
|---|---|
| CMS | Account & balance management |
| FAS | Authorization decisions |
| **TRAMS** | **Transaction repository** |
| Billing | Statement calculations |
| Collections | Delinquent account handling |

Simplified flow:

```
Merchant → Network → FAS (authorizes) → TRAMS (stores & manages transactions)
    → CMS (updates balances) → Billing → Statement
```

Key distinction to hold onto throughout implementation:

- **FAS** answers: *"Can this transaction happen?"* (real-time decisioning; not built for historical research)
- **TRAMS** answers: *"What exactly happened?"* (transaction-centric, full lifecycle, audit trail)
- **CMS** answers: *"What is the account state now?"* (account-centric ledger; current balance/available credit)

> **Developer Note:** When in doubt about whether a piece of data belongs in the Transaction domain vs. the Account/Ledger domain, apply this test: if it describes *the history of a specific purchase/event*, it belongs in TRAM. If it describes *the current standing of an account*, it belongs in CMS/Ledger.

---

## 3. Full Module Roadmap (for context/traceability)

The original roadmap defines 12 modules. Only Modules 1–3A are elaborated in the source document; the rest are listed here as headings only, and require additional specification before development (see Section 10).

1. **TRAMS Architecture Overview** — ✅ Detailed (Section 4)
2. **TRAMS Data Model** — ✅ Detailed (Section 5)
3. **Transaction Lifecycle** — ✅ Detailed (Section 7)
4. **Transaction Inquiry** — ⚠️ Not detailed in source → see [04_transaction_inquiry.md](./04_transaction_inquiry.md)
5. **Transaction Maintenance** — ⚠️ Not detailed in source → see [05_transaction_maintenance.md](./05_transaction_maintenance.md)
6. **Reversals & Adjustments** — ⚠️ Partially covered conceptually (Section 5/7) → functional rules in [06_reversals_adjustments.md](./06_reversals_adjustments.md)
7. **Statement Transaction Processing** — ⚠️ Not detailed in source → see [07_statement_transaction_processing.md](./07_statement_transaction_processing.md)
8. **Chargebacks & Disputes** — ⚠️ Partially covered conceptually (Section 7, State 9–11) → workflow spec in [08_chargebacks_disputes.md](./08_chargebacks_disputes.md)
9. **Batch Processing in TRAMS** — ⚠️ Not detailed in source → see [09_batch_processing.md](./09_batch_processing.md)
10. **TRAMS Integration Points** — ⚠️ Not detailed in source → integration contracts in [10_integration_points.md](./10_integration_points.md)
11. **Troubleshooting / Production Support** — ⚠️ Not detailed in source → runbook in [11_troubleshooting_production_support.md](./11_troubleshooting_production_support.md)
12. **End-to-End VisionPLUS Transaction Flow** — ⚠️ Not detailed in source → sequence view in [12_end_to_end_flow.md](./12_end_to_end_flow.md)

---

## 4. Architecture Overview & Design Rationale

### 4.1 Why a Separate Transaction Repository Is Required

A single card purchase generates a **sequence of independent lifecycle events**, not one record:

```
Day 1  Authorization Request → Approved
Day 2  Merchant Settlement → Financial Posting
Day 30 Statement Generated
Day 45 Customer Raises Dispute
Day 60 Chargeback Processed
Day 90 Chargeback Reversed
```

- **FAS cannot be the repository** — it's optimized for real-time approve/decline decisions (fraud score, velocity, credit check), not long-term historical search across years of transactions.
- **CMS cannot be the repository** — it tracks *account state* (credit limit, balance, available credit), not the evolution of individual transactions.
- **TRAMS is the repository** — because a transaction has a long life (Auth → Partial Reversal → Settlement → Adjustment → Statement → Dispute → Chargeback → Chargeback Reversal) and all these events must remain linked to one another.

**Architecturally:** CMS = Account-Centric. TRAMS = Transaction-Centric.

### 4.2 Core Design Principle

> Accounts change **because** transactions happen. Transactions do not exist **because** accounts change.

Design the system **transaction-first, account-effects-second**:

```
Authorization Engine → Transaction Repository → Account Ledger → Billing Engine → Collections Engine
```

This is the same pattern used by modern processors (Marqeta, Galileo, TSYS, Fiserv) and should be treated as a non-negotiable architectural rule for the Elixir platform, not just a VisionPLUS legacy quirk.

### 4.3 Modern (Elixir/Phoenix) Translation of VisionPLUS Concepts

The original VisionPLUS TRAMS was implemented as mainframe files/COBOL batch programs. For E-VisionPlus, translate these into:

| VisionPLUS Concept | Elixir/Phoenix Equivalent |
|---|---|
| Mainframe files | PostgreSQL tables (event-sourced schema) |
| COBOL batch programs | Oban jobs / Broadway pipelines |
| Online transaction updates | Phoenix Contexts + GenServers |
| Cross-module signaling | Phoenix PubSub / Kafka / RabbitMQ |
| Module boundary (TRAMS/CMS/FAS) | Bounded contexts (`transactions`, `ledger`, `accounts`, `authorization`) |

> **Developer Note:** Treat card processing as fundamentally **event-driven, stateful, concurrent, distributed, and always-on** — this is exactly what Erlang/OTP is designed for. Resist the urge to model it as simple CRUD over a `transactions` table with a `status` column; that pattern breaks down once reversals, partial captures, disputes, and chargebacks are introduced (see Section 7).

---

## 5. Data Model

### 5.1 First Principle

A card transaction is **a graph of related records**, not a single row:

```
Purchase (₹10,000)
  → Authorization → Clearing → Posting → Statement Entry → (Potential) Dispute
```

### 5.2 Required Entities

| Entity | Owner | Key Fields | Notes |
|---|---|---|---|
| **Account** | CMS (TRAM only references it) | `account_id`, `customer_id`, `product_id`, `account_status` | TRAM is a *consumer* of account data, not the system of record. |
| **Card** | TRAM/CMS shared | `card_id`, `account_id`, `pan_token`, `expiry_date`, `status` | One account can have primary, supplementary, and virtual cards — all generating transactions. |
| **Merchant** | TRAM | `merchant_id`, `merchant_name`, `mcc`, `country_code`, `acquirer_id` | Never duplicate merchant name/details into every transaction row — always reference by `merchant_id`. |
| **Authorization** | TRAM (sourced from FAS) | `auth_id`, `account_id`, `card_id`, `merchant_id`, `amount`, `currency`, `approval_code`, `auth_datetime` | Authorization is **not** a financial transaction — it only reserves funds/credit. |
| **Clearing / Settlement** | TRAM | `clearing_id`, `auth_id`, `amount`, `settlement_date`, `network_reference` | Settled amount frequently differs from authorized amount (tips, partial fulfillment, FX) — must be linked back to the original authorization. |
| **Transaction** | TRAM | `transaction_id`, `account_id`, `merchant_id`, `transaction_type`, `status`, `created_at` | The master/aggregate-root object; conceptually *contains* many events. |
| **Transaction Events** | TRAM | `event_id`, `transaction_id`, `event_type`, `payload`, `created_at` | The append-only log driving the state machine (see Section 7). This is the most important table in the schema. |
| **Adjustments** | TRAM | `adjustment_id`, `transaction_id`, `old_amount`, `new_amount`, `reason` | E.g., merchant submitted ₹10,000, corrected to ₹1,000. |
| **Reversals** | TRAM | `reversal_id`, `transaction_id`, `amount`, `reason` | E.g., fuel-pump auth of ₹5,000 reversed down to actual ₹2,000. |
| **Disputes** | TRAM | `dispute_id`, `transaction_id`, `reason_code`, `status`, `created_at` | Raised months after original transaction; must resolve back to original auth/settlement via correlation keys (Section 6). |

### 5.3 Logical Relationship

```
Customer → Account → Card → Transaction
```

> **Developer Note:** Since this source document does not enumerate exhaustive column-level specs (data types, lengths, nullability, indices, currency/precision handling, or multi-currency FX rules), the developer should define these using standard VisionPLUS field conventions (or equivalent ISO 8583 / ISO 20022 field references) and internal data-modeling standards before finalizing migrations. Confirm precision/rounding rules for monetary fields with finance/compliance stakeholders.

### 5.4 Recommended Elixir Representation

```elixir
%Transaction{
  id: uuid,
  account_id: uuid,
  merchant_id: uuid,
  amount: money,
  status: :authorized
}
```

Events (structs, not enum updates):

```elixir
%AuthorizationApproved{}
%SettlementReceived{}
%TransactionPosted{}
%DisputeCreated{}
```

**Recommended core tables:**

```
transactions            (id UUID, account_id, merchant_id, status, ...)
transaction_events       (event_id, transaction_id, event_type, payload, created_at)
transaction_identifiers  (id, transaction_id, identifier_type, identifier_value)
authorizations
clearings
adjustments
reversals
disputes
chargebacks
```

> **Developer Note:** Favor `Transaction Aggregate + Transaction Events + Account Ledger` over a single monolithic transaction table. This design materially simplifies disputes, chargebacks, adjustments, audit trails, statement regeneration, and regulatory reporting later — refactoring away from a flat table after the fact is expensive.

---

## 6. Transaction Identity & Correlation Model

### 6.1 The Problem

A single purchase produces events across multiple independent systems (Merchant → Acquirer → Card Network → Issuer → Processor → Core Banking), and **each system generates a different identifier** for the same business event. Relying on a single internal `id` as "the" transaction identity only works within one database — it breaks the moment you need to match an incoming settlement or dispute message back to its original authorization.

### 6.2 Required External Identifiers

| Identifier | Meaning | Notes |
|---|---|---|
| **STAN** | System Trace Audit Number | Correlates authorization messages; **not globally unique** — rolls over (typically 000001–999999). Never use as a primary key. |
| **RRN** | Retrieval Reference Number | Used for disputes, chargebacks, research. Very important for long-term correlation. |
| **Authorization Code** | Issuer-generated approval code | Often what the cardholder sees during investigation. Not guaranteed unique. |
| **Network Reference** | Generated during clearing (Visa/Mastercard transaction ID) | Format depends on network. |

### 6.3 Design Rule

Always generate and use an **internal UUID** (`transaction_id`) as the source of truth. Store external identifiers separately:

```elixir
%TransactionIdentifier{
  transaction_id: uuid,
  stan: "123456",
  rrn: "987654321234",
  auth_code: "A12345",
  network_ref: "VISA998877"
}
```

This separates **Business Identity** from **External Identity** — critical for matching, disputes, and audits.

### 6.4 Matching Hierarchy

When correlating an incoming message (settlement, reversal, dispute) back to its original transaction, apply identifiers in this priority order (not all networks provide all fields):

```
1. RRN
2. STAN
3. Auth Code
4. PAN
5. Merchant
6. Amount
7. Date/Time
```

> **Developer Note:** This "Transaction Matching" logic is one of TRAM's core responsibilities and is a common source of production defects (duplicate postings, orphaned settlements, unmatched reversals — see Module 11 gap in Section 10). The source document does not specify exact matching tolerances (e.g., amount variance thresholds, time windows for matching). These thresholds must be defined based on real network behavior and VisionPLUS operational history/config — consult existing VisionPLUS parameter tables or acquiring/network documentation if available.

---

## 7. Transaction Lifecycle & State Machine

### 7.1 Core Principle

**A transaction is not a row — it is a state machine.** Do not model it as a single mutable `status` column; model it as an aggregate whose current state is derived from an ordered event log.

### 7.2 Full Lifecycle States

| # | State | Description |
|---|---|---|
| 1 | Initiated | Customer attempts purchase; transaction intent exists; no financial impact yet. |
| 2 | Authorization Requested | Network sends auth request to issuer; TRAM may create a pending transaction even before approval (recommended for modern real-time UX). |
| 3 | Authorized | FAS approves; available credit reduced; **no receivable created yet** — this distinction is critical. |
| 4 | Authorization Maintenance | Incremental auths (e.g., hotel adds ₹5,000 to initial ₹20,000) or partial reversals (e.g., fuel pump authorized ₹5,000, actual ₹2,000) applied before clearing. |
| 5 | Cleared | Merchant submits clearing/settlement record; TRAM must **match** it to the original authorization (see Section 6.4); settled amount often differs from authorized amount. |
| 6 | Posted | CMS creates the receivable; transaction becomes financially real. Note: Authorization affects *Available Credit*; Posting affects *Outstanding Balance* — two separate ledgers. |
| 7 | Statemented | Billing cycle closes; transaction becomes a Statement Transaction, linked to a `statement_id`. |
| 8 | Payment Allocation | Customer payment must (ideally) be allocated at the transaction level — important for disputes, installments, BNPL, and interest calculations. Many legacy systems don't track this granularly; recommend doing so in the new platform. |
| 9 | Disputed | Customer disputes the transaction (often months later); TRAM must preserve original Authorization/Settlement/Posting/Statement records while creating a new Dispute Case. |
| 10 | Chargeback | Network processes a chargeback; amount credited back; transaction lifecycle expands with a Chargeback event. |
| 11 | Chargeback Reversal | Merchant wins representment case; chargeback is reversed. |
| 12 | Closed | Transaction finalized; no further activity expected. |
| 13 | Archived | Retained for regulatory/audit purposes; still searchable years later. |

Full visual flow:

```
Initiated → Authorized → Adjusted/Reversed → Cleared → Posted → Statemented
   → Paid → Disputed → Chargeback → Recovered → Closed → Archived
```

Branching (real behavior, not strictly linear):

```
AUTHORIZED ──► REVERSED
     │
     ▼
CLEARED ──► ADJUSTED
     │
     ▼
POSTED → STATEMENTED → DISPUTED ──► CHARGEBACKED
                            └──► RESOLVED
                                 │
                                 ▼
                              CLOSED
```

### 7.3 Event-Sourced Implementation Approach

Instead of writing `status = 'POSTED'`, append an event and derive state:

```
Event 1: AuthorizationApproved
Event 2: SettlementReceived
Event 3: TransactionPosted
Event 4: StatementGenerated
Event 5: DisputeCreated
```

Current state = replay/fold over the event log. Benefits: perfect auditability, perfect history, easier debugging, easier dispute handling, and painless extension (adding `InstallmentCreated` or `RewardIssued` later requires no schema redesign).

### 7.4 Commands → Events → State

```
Command (e.g., CreateDispute)
   → Validation (transaction exists? posted? within dispute window?)
   → Event (DisputeCreated)
   → State Change (DISPUTED)
```

### 7.5 Recommended Elixir Domain Model

```elixir
defmodule Transaction do
  defstruct [:id, :account_id, :merchant_id, :amount, :state]
end
```

Events:
```
AuthorizationApproved
SettlementReceived
TransactionPosted
TransactionDisputed
ChargebackCreated
```

A reducer applies each event to move state, e.g. `apply(transaction, %AuthorizationApproved{})` moves `NEW → AUTHORIZED`.

Suggested Phoenix context layout:

```
transactions/
  transaction.ex              (aggregate/struct)
  transaction_events.ex        (event definitions + persistence)
  transaction_state_machine.ex (state derivation / valid transitions)
  transaction_search.ex        (inquiry/search — see Section 10, Module 4 gap)
```

Recommended domains (Phoenix Contexts) overall: `accounts`, `cards`, `transactions`, `ledger`, `billing`, `collections`.

> **Developer Note:** "Not literally one GenServer per transaction forever" — treat the per-transaction process model conceptually (command → event → state change), not as a literal long-lived process per transaction, to avoid unbounded process counts in production. Use Phoenix PubSub / Broadway / Oban for propagating events to CMS, Billing, and Collections asynchronously.

---

## 8. Integration Points (High-Level)

| From | To | Purpose |
|---|---|---|
| FAS | TRAM | Authorization approved/declined events feed TRAM's authorization records. |
| TRAM | CMS | Posted transactions create receivables / update outstanding balance. |
| TRAM | Billing | Statemented transactions feed statement generation. |
| TRAM | Collections | Delinquent/disputed/chargeback transactions inform collections workflows. |

> **Developer Note:** The source document does not specify exact message formats, API contracts, retry/idempotency semantics, or failure-handling behavior for these integrations (this is the "Module 10 — Integration Points" gap, see Section 10). Before implementation, define: (1) event schema/versioning for `AuthorizationApproved`, `TransactionPosted`, etc.; (2) idempotency keys to prevent duplicate posting on retry; (3) dead-letter/error-handling strategy for failed downstream consumers (e.g., Oban job retries with backoff, PubSub failure handling).

---

## 9. Non-Functional / Architectural Guidance Summary

- Model transactions as an **event-sourced aggregate**, not a mutable row with a status column.
- Always separate **Business Identity** (internal UUID) from **External Identity** (STAN/RRN/Auth Code/Network Ref).
- Treat **TRAM as authoritative for transaction history**; CMS remains authoritative for account/balance state. Do not duplicate one system's source-of-truth data as another's.
- Favor **asynchronous, event-driven propagation** (Phoenix PubSub, Broadway, Oban) between Transaction, Ledger, Billing, and Collections domains over synchronous coupling.
- Maintain full auditability: every lifecycle transition should be reconstructable from the event log alone (supports regulatory/audit requests such as "show every lifecycle event for transaction XYZ").

---

## 10. Explicit Gaps Requiring Developer / SME Input

The source training document stops short of a complete functional spec. Each gap below has been drafted into its own file (from general VisionPLUS/card-management domain knowledge — **not extracted from the source docx**), so the developer has a concrete starting spec to validate rather than a blank page. Each linked file ends with its own **Open Questions** section for SME/product sign-off.

1. **Transaction Inquiry (Module 4)** → [04_transaction_inquiry.md](./04_transaction_inquiry.md) — search criteria, result/detail views, cardholder-vs-internal presentation, PCI scope.
2. **Transaction Maintenance (Module 5)** → [05_transaction_maintenance.md](./05_transaction_maintenance.md) — correction categories, maker-checker controls, reason codes, audit trail.
3. **Reversals & Adjustments — detailed rules (Module 6)** → [06_reversals_adjustments.md](./06_reversals_adjustments.md) — full/partial reversal triggers and rules, credit/debit adjustment rules, approval thresholds, statement/dispute interaction.
4. **Statement Transaction Processing (Module 7)** → [07_statement_transaction_processing.md](./07_statement_transaction_processing.md) — cycle cutoff rules, transaction grouping, per-line data contract, statement regeneration.
5. **Chargebacks & Disputes — full workflow (Module 8)** → [08_chargebacks_disputes.md](./08_chargebacks_disputes.md) — retrieval requests, dispute intake/eligibility, provisional credit, chargeback/representment/arbitration flow, reason-code handling.
6. **Batch Processing (Module 9)** → [09_batch_processing.md](./09_batch_processing.md) — daily load, posting cycle, auto-expiry sweep, statement extraction, purge/archive, reconciliation jobs.
7. **Integration Contracts (Module 10)** → [10_integration_points.md](./10_integration_points.md) — FAS/CMS/Billing/Collections/Letter Management contracts, idempotency, retry/outbox pattern.
8. **Production Support / Troubleshooting (Module 11)** → [11_troubleshooting_production_support.md](./11_troubleshooting_production_support.md) — missing/duplicate transaction, posting failure, and reconciliation-break diagnostic playbooks.
9. **End-to-End Flow (Module 12)** → [12_end_to_end_flow.md](./12_end_to_end_flow.md) — full sequence view spanning Authorization → Posting → Billing → Statement → Payment → Delinquency → Collections, with cross-references into every file above.
10. **Module 3B — Ledger Architecture** — Explicitly flagged in the source as the next recommended topic (double-entry accounting design, Transaction Store vs. Ledger distinction, PostgreSQL/Elixir ledger implementation) but not yet written, and not drafted here either (out of 