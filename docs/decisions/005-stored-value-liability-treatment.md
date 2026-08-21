# VMU-ADR-005 — Debit, Prepaid and Wallet balances are liabilities; account-code conflicts resolved

## Status

**Accepted** — 2026-08-02. Accounting treatment decided. **Execution against live posting paths is blocked** — see Consequences.

## Context

`cms_ledger_entries` is written by two code sets that define their own account codes in their own module docstrings, and disagree where they overlap:

| Code | `FAS.GL.CardAccountCodes` | `CMS.InternalGlPoster` |
|---|---|---|
| 2001 | Customer Credit Liability | Interest income |
| 2002 | HCS Parent Account Payable | Fee income |
| 4001 | Fee Revenue | Interchange income |
| 5001 | Interchange / MDR Expense *(debit-normal)* | Debit deposit liability *(credit-normal)* |
| 5002 | ITS FAR Expense | Prepaid stored-value liability |
| 1006 | HCS Employee Pool Receivable | Bank cash / clearing |
| 5003 | — | Wallet stored-value liability *(registered in no chart at all)* |

5001 is the worst case: an expense account and a liability account sharing one number with opposite normal balances.

The reconciled 26-account chart inherited from `WalletGl.ChartOfAccounts` has **no accounts for stored value**, because the poster it was reconciled against was credit-only. Debit, Prepaid and Wallet arrived afterwards (Way4 parity Phase 1) and were given codes in the 5xxx expense range, two of which were already occupied.

## Problem Statement

What is the correct accounting treatment for Debit, Prepaid and Wallet balances, and which account codes should carry them?

## Decision

**Stored-value balances are liabilities.** A debit deposit, a prepaid load and a wallet balance are all funds the bank owes the customer — not receivables, and not expenses. They are booked in the 2xxx liability range:

| Code | Account | Class | Replaces |
|---|---|---|---|
| **2004** | Debit Deposit Liability | liability, credit-normal | 5001 |
| **2005** | Prepaid Stored-Value Liability | liability, credit-normal | 5002 |
| **2006** | Wallet Stored-Value Liability | liability, credit-normal | 5003 |
| **3002** | Bank Cash / Funding Clearing | asset, debit-normal | 1006 |

And the revenue conflicts resolve to the reconciled chart's meaning:

| Event | Was | Now |
|---|---|---|
| Interest income (CREDIT product) | 2001 *(a liability account)* | **4002** Interest Income |
| Fee income (CREDIT product) | 2002 *(HCS payable)* | **4001** Fee Revenue |
| Interchange income | 4001 *(fee revenue)* | **4003** Interchange Income |

`normal_balance` is derived from `account_class` and enforced by a database check constraint, so the liability treatment cannot be silently inverted at a call site.

## Alternatives Considered

1. **Keep stored value in the 5xxx range** — rejected. They are not expenses, and two of the three codes collide with real expense accounts that have the opposite normal balance.
2. **Treat stored value as negative receivables** — rejected. It misrepresents the bank's obligation and breaks any balance-sheet classification.
3. **Give each product its own numbering block** — considered, rejected as premature. The 2xxx liability range is not near exhaustion.

## Rationale

Stored value is a deposit-like obligation. Booking it as a liability is the only treatment consistent with the balance-sheet equation and with how the same balances are already described to customers.

## Consequences

**Positive.** One coherent chart. Interest, fee and interchange income become separable in the trial balance. Normal balance is enforced by the database rather than by convention.

**⚠️ Execution is blocked on two things this decision does not settle.**

1. **`CMS.CoreBankingAdapter` exports `gl_account_dr` / `gl_account_cr` to the bank's core banking system** after every EOD cycle, for the bank's own GL reconciliation. These codes are an **external contract**. Remapping them changes what the bank's ledger receives, and cannot be done by a code edit alone — the receiving GL must recognise 2004/2005/2006/3002 first.

2. **Historical rows become ambiguous at the cutover.** Rows written before the change have 5001 meaning "debit deposit liability"; rows after have it meaning "interchange expense". Any balance query spanning the boundary is wrong unless historical rows are migrated or the cutover date is carried explicitly.

**Scope is wider than first assessed.** Hardcoded account codes are not confined to `InternalGlPoster`. They also appear in `cms/payment_intake`, `cms/payment_reversal`, `cms/statement_reversal`, `cms/credit_balance_refund`, `cms/financial_adjustment`, `col/settlement_command`, `col/write_off_processor`, `asm/operator_portal`, and are inherited implicitly by `cms/fee_waiver` (which swaps the original entry's pair). `cms/statement_reversal` independently uses 2001 as an income account, confirming the collision is not isolated to one module.

**Therefore the remap remains Phase C**, after the Phase B shadow diff, and requires a bank-side conversation plus a historical-data plan. The decision above is what Phase C will implement; it is not implemented by this ADR.

## Related Documents

- [`docs/gl/GL_Module_Design_and_Plan.md`](../gl/GL_Module_Design_and_Plan.md) §5 — phasing
- `VmuCore.GL.ChartOfAccounts.conflicts/0` — the live worklist
- `VmuCore.Posting.Rules.pending_cutover/0` — the 12 rules still on legacy codes

## Review Date

Review when the core banking GL has been aligned, which is the gating dependency for Phase C.
