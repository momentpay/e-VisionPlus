# E-VisionPlus — Product Overview

**A modern, full-lifecycle credit card management platform**
*Prepared for business stakeholder review — July 2026*

---

## What E-VisionPlus Is

E-VisionPlus is a complete credit card issuing and management platform — built to give a bank or fintech everything needed to launch and run a credit card program: approving transactions in real time, managing customer accounts and billing, issuing and replacing physical/virtual cards, handling disputes and collections, and giving operations staff a secure console to run it all.

It is designed for **full functional parity with VisionPlus**, the industry-standard card management system used by major banks worldwide — meaning existing VisionPlus customers and staff can migrate to E-VisionPlus without relearning how the business works.

---

## The Customer Journey, End to End

```
Customer applies → Account opened → Card issued → Card activated
   → Customer swipes card → Transaction authorized in real time
      → Purchase posted to statement → Customer pays
         → (if something goes wrong) Dispute raised → Resolved
            → (if unpaid) Collections engages → Recovered or written off
```

Every one of these steps is built, working, and has been tested against real data in our development environment.

---

## What's Built and Working Today

### 1. Real-Time Transaction Authorization (the "swipe" moment)

When a cardholder taps, swipes, or enters a card online, a decision has to be made in **milliseconds**: approve or decline. This is the highest-stakes, highest-volume part of any card system — it must never go down and must never be wrong.

**What's operational:**
- Full authorization decisioning: checks card validity, available credit, fraud rules, PIN, and chip cryptogram (EMV) — all within the transaction window
- Stolen/lost card blocking — instantly declines any transaction on a reported card
- Fraud and risk scoring integrated into every transaction, with automatic pass-through if the risk engine is unavailable (never blocks legitimate business)
- Full support for hotel/car-rental style transactions (pre-authorize an estimate, then adjust up or down as the final bill is known)
- Automatic handling of reversals (cancelled transactions) and network retries without creating duplicate charges
- A "stand-in" fallback so transactions can still be approved within safe limits even if the core system is briefly unreachable
- Hardware-grade security for card verification (CVV), PIN checks, and chip authentication
- Live dashboards showing approval rates, decline reasons, and system health in real time

**Business impact:** This is the engine that makes the card usable. It has been built to the same security and compliance bar (Visa/Mastercard EMV certification-grade) that global card networks require.

---

### 2. Transaction History & Record-Keeping

Every single thing that happens to a transaction — from the moment it's authorized to the moment it's fully settled, statemented, possibly disputed, and eventually archived — is tracked as a complete, tamper-proof history.

**What's operational:**
- Every transaction's full life story is recorded and searchable: authorized → cleared → posted → appeared on statement → (if disputed) → resolved
- Automatic matching of incoming settlement files from Visa/Mastercard to the original transaction, so the books always reconcile
- Automatic posting of transactions to the customer's account ledger with no risk of double-counting
- A three-way reconciliation report comparing our records, the network's settlement files, and the general ledger — surfaces discrepancies for operations to review before they become a problem
- Auto-release of holds on transactions that are authorized but never completed (e.g., a hotel pre-auth that's never finalized), so customers aren't left with credit tied up unfairly

**Business impact:** This is the audit trail regulators and auditors will ask for — a complete, provable record of what happened to every dollar and every transaction.

---

### 3. Account & Billing Management

This is the heart of the credit relationship: credit limits, interest, fees, monthly statements, and payments.

**What's operational:**
- Full account lifecycle: opening, credit limit management, temporary limit increases, product upgrades/downgrades, blocking, closure, and reopening (with proper safeguards — e.g., an account can't be closed with an outstanding balance or an open dispute)
- Interest and fee calculation engines (annual fees, late fees, cash advance fees, foreign transaction fees) — fully configurable per product and per market
- Automated monthly billing cycle: interest accrual, fee assessment, statement generation, and delinquency tracking, all running as an automated nightly process
- Multiple ways for customers to pay: gateway, direct debit, branch payment — with automatic allocation across what's owed (fees first, then interest, then principal, per configurable rules)
- **Auto-pay**: customers can set up automatic payment of their minimum due, full balance, or a fixed amount each month
- Handling of returned/bounced payments — automatically reverses the payment, reassesses any fee, and restores the correct balance
- Overpayment refunds — if a customer pays more than they owe, that credit balance can be tracked and refunded
- Dormancy detection — flags accounts with no activity so the business can decide how to treat them
- Support for installment plans (EMI), balance transfers, and promotional interest rates that automatically expire on schedule

**Business impact:** This is the profit engine — it's what determines how much interest and fee revenue is earned and how accurately the bank bills its customers.

---

### 4. Card Issuance & Lifecycle Management

Managing the physical or virtual card itself — separate from the account it's attached to.

**What's operational:**
- Full card lifecycle tracking: ordered → personalized → dispatched → activated → active → blocked → replaced/expired
- Card activation via phone (IVR) or first use
- PIN issuance and management, with encrypted, HSM-grade security (PINs are never stored or visible in plain text)
- **Lost/stolen card handling**: reporting a card lost or stolen instantly blocks it across the entire system and issues a replacement with a brand-new card number — the compromised number can never be used again
- **Damaged card replacement**: keeps the same card number (no disruption to the customer's saved cards/subscriptions)
- **Automatic renewal**: cards approaching expiry are automatically renewed weeks in advance, so customers are never caught with an expired card
- Full history of every card ever issued on an account is retained — nothing is overwritten or lost
- Card replacement fees (waivable by staff when appropriate)

**Business impact:** This directly affects customer experience and fraud losses — fast, correct handling of lost/stolen cards protects both the customer and the bank.

---

### 5. Disputes & Chargebacks

When a customer says "I didn't make this purchase" or "I never received what I paid for."

**What's operational:**
- Full dispute intake and case management, following the same lifecycle used by Visa/Mastercard: filed → chargeback → merchant response (representment) → resolution
- Automatic provisional credit — customers get their money back while the dispute is investigated, as regulations require
- Deadline tracking so disputes are never lost to a missed regulatory timeline
- Full linkage between the dispute case and the original transaction record, so investigators see the complete picture

**Business impact:** Protects customers and keeps the bank compliant with network rules and consumer protection regulations.

---

### 6. Operations & Security Console

The back-office tool that bank staff use every day to serve customers and manage the portfolio.

**What's operational:**
- Secure staff login with role-based access — a call center agent, a supervisor, a risk analyst, and an administrator each see and can do different things
- **"Maker-checker" controls** on every financially sensitive action (fee waivers, credit adjustments, limit changes) — one staff member requests it, a different, authorized staff member must approve it, with dollar-amount authority limits per role
- A unified approval queue so supervisors can review and action pending requests in one place, instead of hunting across systems
- Full audit trail of every action staff take, and every time a staff member looks at a customer's private information — answering "who did what, and who looked at this customer's data, and when"
- Customer search and full account/transaction inquiry tools for customer service staff
- An exception queue surfacing anything that needs human attention (unmatched transactions, aging holds, fraud alerts)

**Business impact:** This is what makes the platform auditable and safe to operate — every sensitive action has an owner and a trail, which is exactly what regulators and internal audit expect.

---

## What This Means for the Business

| Capability | Status |
|---|---|
| Accept and authorize card transactions in real time | ✅ Live |
| Full EMV chip, PIN, and fraud security | ✅ Live |
| Complete transaction history & audit trail | ✅ Live |
| Automated monthly billing, interest, and fees | ✅ Live |
| Customer payments, including auto-pay | ✅ Live |
| Card issuance, replacement, and renewal | ✅ Live |
| Dispute and chargeback handling | ✅ Live |
| Secure staff console with approval controls | ✅ Live |
| Full audit and compliance trail | ✅ Live |

**In short: a customer can be onboarded, get a working card, use it, get billed correctly every month, pay, have their card replaced if lost, and dispute a transaction if needed — and every step is secure, auditable, and automated.**

---

## What's Still Ahead

A few specialized areas are being built out next, each adding incremental capability on top of the solid foundation above:

- **Card-level spending controls** — letting a business set granular limits per card (e.g., a corporate card that can only be used for travel)
- **Collections workflow** — more advanced tools for managing overdue accounts (payment plans, agency handoff)
- **Credit decisioning** — automating new-application approval and credit-limit decisions
- **Merchant & loyalty program tools** — rewards points and merchant-funded offers
- **Corporate card programs** — company-level credit facilities with multiple employee cards

None of these block day-one operation of the core card program — they extend it.

---

## Why This Matters

This platform was built to a standard where **every feature has been tested against real transaction data**, not just written and assumed to work. Financial calculations, security controls, and audit trails have all been verified end-to-end before being marked complete. That means what's listed as "done" above is genuinely ready to demonstrate and rely on — not a roadmap promise.

---

*This document summarizes business capability, not technical implementation. For technical/architectural detail, see the engineering documentation index.*
