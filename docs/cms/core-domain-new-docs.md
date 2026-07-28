# Koṣa Architecture Handbook

**Document:** 02 - Core Domain Model

**Version:** 1.0 (Draft)

**Status:** Foundational Domain Model

---

# 1. Purpose

This document defines the core business objects of the Koṣa Platform and the relationships between them.

These objects form the canonical domain model used across every module within Koṣa.

Every future service, API, database schema, and event model must align with this document.

---

# 2. Goals

The domain model should:

- Represent real-world financial relationships
- Be independent of payment rails
- Support retail and corporate banking
- Support issuing and acquiring
- Support merchants and consumers
- Support multiple products per customer
- Support products without financial accounts
- Support multiple financial accounts per product
- Be cloud-native and event-driven

---

# 3. Core Domain Hierarchy

```
Party
    │
    ▼
Relationship
    │
    ▼
Portfolio
    │
    ▼
Arrangement
    ├───────────────────────────────────────────────┐
    │                                               │
    ▼                                               ▼
Financial Account(s)                      Product Instance(s)
                                                  │
                          ┌───────────────────────┼────────────────────────┐
                          │                       │                        │
                    Payment Instrument      Digital Capability     Financial Capability
                          │
            ┌─────────────┼────────────────────────────────────┐
            │             │            │            │           │
         Card          QR Code       UPI VPA     Payment Link  Wallet Token
            │
      ┌─────┼─────────────┐
      │     │             │
 Physical  Virtual     Network Token
```

---

# 4. Domain Objects

## 4.1 Party

### Definition

A Party is any legal or operational entity participating in the financial ecosystem.

### Examples

- Individual
- Merchant
- Corporate
- Bank
- FinTech
- Government
- Partner
- Regulator

### Responsibilities

A Party owns business relationships.

A Party never owns money directly.

Money always belongs to Financial Accounts.

---

## 4.2 Relationship

### Definition

A Relationship represents a commercial or legal agreement between Koṣa and a Party.

Examples

Retail Banking

Merchant Acquiring

Corporate Banking

Payroll

Wallet Membership

Credit Relationship

---

### Why Relationship instead of Contract?

Contracts expire.

Relationships evolve.

One relationship may contain multiple legal contracts over time.

The business relationship is more stable than individual contracts.

---

## 4.3 Portfolio

### Definition

A Portfolio is a logical collection of Arrangements that serve a common business objective.

Examples

Daily Banking

Business Banking

Merchant Business

Travel

Investments

Corporate Cards

---

### Benefits

A Portfolio allows:

- grouped reporting
- grouped pricing
- grouped servicing
- grouped permissions

without affecting the financial model.

---

## 4.4 Arrangement

### Definition

An Arrangement is the fundamental business agreement that combines Products and Financial Accounts to deliver a business capability.

This is the most important object in Koṣa.

Everything delivered to a customer belongs to an Arrangement.

---

### Examples

Daily Banking Arrangement

contains

- Savings Account
- Debit Card
- Mobile Banking
- UPI
- QR
- Rewards

---

Credit Arrangement

contains

- Credit Account
- Credit Card
- Installment Plan

---

Merchant Arrangement

contains

- Settlement Account
- POS
- QR
- Soundbox

---

### Responsibilities

An Arrangement defines:

- ownership
- pricing
- lifecycle
- eligibility
- status
- servicing

It does NOT perform accounting.

---

## 4.5 Financial Account

### Definition

A Financial Account stores financial value.

---

Responsibilities

- balance
- currency
- posting
- settlement
- accounting
- interest
- reconciliation

---

Examples

Savings

Current

Credit

Loan

Wallet Balance

Settlement

Escrow

Suspense

---

### Important Rule

A Financial Account never knows whether it belongs to:

- Debit Card
- Wallet
- QR
- Merchant
- Loan

It only manages money.

---

## 4.6 Product Definition

### Definition

A reusable business template.

---

Contains

- pricing
- limits
- workflows
- fees
- rewards
- interest rules
- risk policies

---

Examples

Visa Infinite

Merchant QR

Personal Loan

Consumer Wallet

Corporate Credit Card

---

## 4.7 Product Instance

### Definition

A customer-specific implementation of a Product Definition.

Example

Product Definition

Visa Infinite

↓

Product Instance

John's Visa Infinite Card

---

Responsibilities

- lifecycle
- status
- activation
- expiry
- servicing
- ownership

No accounting logic.

---

## 4.8 Payment Instrument

### Definition

A Payment Instrument is the customer-facing mechanism used to access a Product Instance.

---

Examples

Physical Card

Virtual Card

QR

UPI

Apple Pay

Google Pay

Samsung Pay

Payment Link

Virtual Account

NFC Wearable

---

One Product Instance may expose multiple Payment Instruments.

---

# 5. Business Relationships

The domain model intentionally avoids rigid parent-child dependencies.

Instead, objects collaborate.

```
Arrangement

├── Financial Account

├── Product Instance

└── Association

Product Instance

↓

Financial Account
```

This allows:

- multiple products sharing one account

- one product using multiple accounts

- products without accounts

---

# 6. Typical Business Examples

## Retail Banking

```
Party

John

↓

Relationship

Retail Banking

↓

Portfolio

Daily Banking

↓

Arrangement

Daily Banking

↓

Savings Account

↓

Debit Card

↓

Physical Card

Virtual Card

Apple Pay
```

---

## Merchant

```
Merchant

↓

Merchant Relationship

↓

Merchant Portfolio

↓

Merchant Arrangement

↓

Settlement Account

↓

Merchant QR

↓

Dynamic QR

Static QR

Soundbox

POS
```

---

## Lending

```
Party

↓

Credit Relationship

↓

Loan Portfolio

↓

Loan Arrangement

↓

Loan Account

↓

Loan Product

↓

Disbursement
```

---

# 7. Why This Model?

This model separates:

Business

↓

Money

↓

Capabilities

↓

Access Channels

This separation dramatically reduces coupling between services.

---

# 8. Design Decisions (ADR)

## ADR-002

Relationship replaces Contract.

Reason

Business relationships live longer than legal contracts.

---

## ADR-003

Financial Accounts never own Products.

Reason

Money should remain independent of business capabilities.

---

## ADR-004

Payment Instruments are separate from Products.

Reason

One product may expose many instruments.

---

## ADR-005

Arrangement is the primary business aggregate.

Reason

It naturally groups products, money, pricing and servicing into one lifecycle.

---

# 9. Domain Boundaries

This document defines only business objects.

It intentionally excludes:

- Ledger Design
- Transaction Processing
- Authorization
- Pricing Engine
- Risk Engine
- Merchant Routing
- ISO8583
- Open Banking

Those are covered in subsequent documents.

---

# 10. Key Takeaways

The Koṣa Platform is built around five independent concerns.

| Concern | Domain Object |
|----------|---------------|
| Identity | Party |
| Business Relationship | Relationship, Portfolio, Arrangement |
| Financial Value | Financial Account |
| Business Capability | Product Definition, Product Instance |
| Customer Interaction | Payment Instrument |

Every feature introduced into Koṣa must fit into one of these five concerns.

If it does not, the domain model should be revisited before implementation.

---

# 11. vmu_core Alignment Status (2026-07-28)

Discussion outcome between the architecture team and the vmu_core implementation, confirmed point-by-point. This section tracks what is actually built against this model today, so it doesn't drift silently out of sync with the handbook above.

| Domain Object | Status in vmu_core | Notes |
|---|---|---|
| **Party** | Implemented as `Shared.Customer` | Party and Customer are treated as the same concept in vmu_core — no separate Party layer. Revisit only if a non-customer party type (e.g. a Merchant or Partner as a first-class record) is needed later. |
| **Relationship** | Not implemented | Confirmed valuable, deliberately deferred. vmu_core currently has no concept between Customer and Arrangement. Recorded here so it isn't forgotten: if/when Koṣa needs multiple concurrent commercial relationships per customer (e.g. Retail + Merchant on the same Party), this is the layer to add. |
| **Portfolio** | Not implemented | Same status as Relationship — confirmed useful for grouped reporting/pricing/servicing, deliberately deferred. No current vmu_core requirement forces it yet. |
| **Arrangement** | **Implemented**, 2026-07-28 — `VmuCore.CMS.Arrangement` (`cms_arrangements` table) | One row per customer-relationship: `customer_id` + `product_type` (`CREDIT`/`DEBIT`/`PREPAID`/`CORPORATE_FACILITY`/`CORPORATE_EMPLOYEE`/`CORPORATE_FLEET`) + `account_ref` (polymorphic pointer, no DB FK — the referenced tables use inconsistent PK types) + `opened_at`. Deliberately thin: no `status`, no balance — those stay authoritative on the real product table (`CMS.Account`/`DebitAccount`/`PrepaidAccount`/`HCS.EmployeeCard`/`FleetCard`), read live via `account_ref`, never duplicated. Recorded automatically at every account-opening call site (Credit, Debit, Prepaid, HCS facility/employee/fleet). Surfaced on the Customer admin detail page as an "Arrangements (All Products)" panel replacing the old credit-only "Linked Accounts" view — this closes the original UX gap that started this discussion (Debit/Prepaid/Corporate cards had no visible Customer linkage in the admin UI). |
| **Financial Account** | Not extracted as its own layer — stays merged into each product's own account table | `CMS.Account`/`DebitAccount`/`PrepaidAccount` each already carry both the "financial account" (balance, currency, posting) and "product instance" (status, lifecycle) concerns in one table. Splitting them is a real, larger migration with no concrete driver yet (no case today needs one product to span multiple financial accounts, or one account shared by multiple products). Deferred, not rejected. |
| **Product Definition** | Unchanged — no code change | `ParameterEngine`'s SYS→BANK→LOGO→BLOCK cascade already serves this role (reusable pricing/limits/fee templates resolved per card). No new table needed. |
| **Product Instance** | Unchanged — already the product tables themselves | `CMS.Account`/`DebitAccount`/`PrepaidAccount`/`HCS.EmployeeCard`/`FleetCard` already are the Product Instance layer (lifecycle, status, activation, ownership — no accounting logic beyond what's noted under Financial Account above). |
| **Payment Instrument** | **Realized without a new table**, 2026-07-28 | `VmuCore.CTA.Card`'s existing three-way polymorphism (`account_id` / `debit_account_id` / `prepaid_account_id`, exactly one set) already *is* "Payment Instrument → Card → (Credit, Debit, Prepaid)". Added `Card.instrument_product_type/1`, a named helper deriving which product a card belongs to from which ref is set, so callers stop re-deriving it inline. A standalone `PaymentInstrument` umbrella table above `cta_cards` (to also cover QR/UPI/wallet-token instruments per §4.8's example list) is deliberately deferred until a second real non-card instrument type actually needs to be issued — building it now would be speculative, since every current instrument in vmu_core is a card. |

**Summary of what changed in code:** `VmuCore.CMS.Arrangement` + `VmuCore.CMS.Arrangements` (new), wired into `DebitAccountOpening.open/1`, `PrepaidAccountOpening.open/1`, `AccountComponent`'s credit wizard save, and `HCS.CompanyOnboarding`/`FleetOnboarding`'s three card-issuance paths; `Card.instrument_product_type/1` (new); `CustomerComponent`'s admin detail page rebuilt around a cross-product "Arrangements" panel.