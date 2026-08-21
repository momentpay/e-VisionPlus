# Debit Card Issuing — Product Feasibility & Requirements

**Status:** 📝 New-product planning doc (2026-07-11) — not started. Written after
confirming with the team that no debit card issuing exists in the current
system: `LogoParameter.product_type` accepts `"DEBIT"` as a stored value, but
it is pure reference metadata (only touched by the admin form, never read by
any business logic anywhere in `lib/vmu_core/`).

---

## 1. Purpose & Scope

A debit card draws down a real cash balance the cardholder already owns
(a demand-deposit / current account), rather than a line of credit. There is
no credit limit, no interest accrual, no minimum payment, no statement
billing cycle in the VisionPlus sense — authorization is a simple "is there
enough balance" check, and a good transaction **settles immediately against
that balance** rather than accruing toward a monthly bill.

**Boundary test:** anything that assumes revolving credit (limit, APR,
minimum payment, delinquency bucket) does not belong to this product; a debit
account's "balance" is a deposit liability, not a receivable asset — the GL
entries run in the *opposite* direction from a credit card's.

## 2. Why This Doesn't Fit Today's Architecture Without Real Work

This is the most structurally significant of the six products, not just the
least-built. Confirmed by direct inspection, not assumption:

- **`CMS.Account`'s schema requires `credit_limit`** (`@required` list in
  `lib/vmu_core/cms/account.ex`) — not optional, not nullable. A debit
  account has no credit limit at all; forcing one to exist (e.g. `0`) would
  corrupt every downstream calculation that assumes `credit_limit` is a real
  ceiling (OTB math, delinquency bucketing, statement minimum-payment calc).
- **`CMS.AccountStateCoordinator`** — the per-account GenServer that is the
  *entire* hot-path authorization engine — holds `open_to_buy` /
  `cash_open_to_buy` as its core state and its authorization check
  (`check_open_to_buy/2`) is fundamentally "is the amount ≤ remaining credit
  line," not "is the amount ≤ available balance." A debit authorization is a
  different check against a different kind of number (a real balance that
  goes *down* on spend and *up* on deposit, with no "limit" ever restored by
  a payment).
- **EOD billing cycle** (`cms/eod/*`) — interest accrual, minimum payment,
  statement generation, delinquency bucket aging — none of this applies to a
  debit account. Running EOD against a debit account today would try to
  accrue interest on a credit facility that doesn't exist.
- **GL direction is reversed.** A credit card's balance is an *asset*
  (amount the bank is owed). A debit account's balance is a *liability*
  (amount the bank owes the depositor). Every GL posting helper in
  `CMS.InternalGlPoster`/`FeeEngine` assumes the credit-card direction.

None of this means debit is unbuildable — it means it needs a **parallel
account type**, not a flag on the existing one.

**⚠ Cross-repo finding, 2026-07-11 — worth a decision, not a silent
default.** The sibling `wallet-app` repo already has real, tested
infrastructure that is almost exactly this "parallel account type":
`wallet_accounts` (account open/freeze/tier lifecycle) + `wallet_ledger` (a
genuine double-entry engine — balanced debit=credit invariant, idempotent
via reference_id, reversal support, freeze-aware) + `wallet_cards` (card
issuance against that account, including `LinkedCard` for externally-linked
funding sources — conceptually the same shape as a debit card's link to a
deposit account). If debit stays in vmu_core per the current plan, it will
need to build this same balance/ledger/account combination from scratch
against a schema that actively resists it (§2 above); if it goes to
wallet-app instead, most of the hard part already exists and is tested.
Flagging this clearly rather than deferring to the stated plan, since it's
the same kind of thing this whole review has repeatedly caught — worth a
deliberate decision either way, not an assumption.

## 3. What's Genuinely Reusable

- **SYS → BANK → LOGO → BLOCK parameter cascade** (`ParameterEngine`) — the
  4-level config hierarchy is product-agnostic; a debit LOGO can live in the
  same table with debit-relevant fields (or a debit-specific parameter
  extension) without touching the cascade mechanism itself.
- **CTA's card entity + lifecycle** (`cta_cards`, `Card`, `CardStateMachine`,
  `CardLifecycle`) — issuance, activation, block/unblock, replace/renew,
  channel controls are all card-*plastic* concerns, identical whether the
  underlying account is credit or debit. This is directly reusable as-is —
  a debit card is still a card.
- **FAS switch/HSM/PIN infrastructure** — ISO 8583 routing, PIN block
  verification, hot-card cache — transport-and-security concerns that don't
  care what's behind the account.
- **ASM** (auth, roles, audit, maker-checker), **Module Configuration
  Framework**, **CIF/Customer** — all product-agnostic, reusable unchanged.
- **TRAMS clearing/settlement** — the matching engine and interchange logic
  are network-message concerns, largely reusable, though debit interchange
  economics differ from credit (Durbin-style/regulated rates in some
  markets) and would need their own `InterchangeRate`/`MdrRate` rows, not
  code changes.

## 4. Net-New Build Required

| Area | What's needed |
|---|---|
| Account model | A `DebitAccount` (or a `product_family` discriminator + a parallel schema) with `available_balance` instead of `credit_limit`/`open_to_buy` |
| Authorization | A debit-specific check in (or parallel to) `AccountStateCoordinator` — balance-sufficiency, not credit-line-sufficiency; **real-time balance debit on approval**, not "pending until EOD" |
| Funding | A deposit/load mechanism — debit accounts need money put into them before they can be spent (bank transfer, cash deposit, payroll credit) — nothing like this exists today |
| GL | Liability-side posting (opposite direction from credit), reversed fee/interchange treatment |
| No billing cycle | Debit has no statement/minimum-payment/interest — EOD jobs must explicitly exclude debit accounts, not just "run and do nothing" |
| Overdraft (if in scope) | A market-specific decision — some debit products allow a small overdraft buffer, which reintroduces a tiny credit-like concept and its own regulatory disclosure requirements |

## 5. Feature Inventory (draft — validate with product before build)

| FR | Feature |
|---|---|
| 001 | Debit account opening linked to a funding source (own deposit, payroll, transfer-in) |
| 002 | Real-time balance debit on approved authorization (no billing cycle) |
| 003 | Available-balance authorization check (balance − holds ≥ amount) |
| 004 | Card issuance under a debit account (reuses CTA's card entity) |
| 005 | Deposit/load transaction types (transfer-in, cash deposit, payroll credit) |
| 006 | Optional overdraft buffer with its own limit + fee model (market-dependent) |
| 007 | No interest, no minimum payment, no delinquency bucket |
| 008 | Balance/mini-statement inquiry (IVR/app/ATM) |
| 009 | Regulatory reporting specific to deposit products (differs from credit reporting/Metro2) |

## 6. Phased Implementation Plan (high-level — refine before starting)

1. **Phase D1 — Account model decision + schema.** Confirm: separate schema
   (`cms_debit_accounts`) vs. a shared-table `product_family` discriminator
   on `cms_accounts` with product-specific fields nullable. Recommend
   separate schema given how different the required fields and semantics
   are — a shared table risks exactly the kind of "nullable field nobody
   enforces" bugs found repeatedly across this project's other modules this
   session (LMS, DPS, HCS all had "config/field exists, nothing reads it").
2. **Phase D2 — Balance + funding.** `available_balance` field, deposit/load
   transaction types, real-time debit-on-approval path (parallel to, not
   inside, `AccountStateCoordinator`'s credit logic).
3. **Phase D3 — Card issuance wiring.** Point CTA's existing `Cards.issue/1`
   at a debit account instead of a credit account — should be close to
   free given CTA's card entity is already account-type-agnostic at the
   `account_id` foreign-key level.
4. **Phase D4 — GL + reporting.** Liability-side posting, exclude debit
   accounts from EOD interest/statement jobs, deposit-product regulatory
   reports.
5. **Phase D5 — Ops UI.** Admin screens for debit account view/funding/
   overdraft management (if in scope).

## 7. Open Questions — ANSWERED 2026-07-26 (Way4 parity plan Phase 1 item 4)

1. **Overdraft**: No overdraft in v1. Authorization strictly requires
   `available_balance ≥ amount`. Can be added later as its own buffer +
   fee model without touching v1's core path.
2. **Funding sources**: internal transfer/admin-manual **and** external
   bank transfer / cash deposit. No real bank-rail integration exists in
   either repo, so external channels are modeled as real transaction
   records with a `channel` tag + `external_reference` field for future
   reconciliation, but with **no live rail call** — same "data model now,
   real integration later" pattern already shipped and accepted for
   Avenza's Prepaid `PrepaidLoad.channel` (P-UI1, confirmed working
   precedent, not a new idea).
3. **Market**: UAE/AED (CBUAE) first, but **configurable, not hardcoded**
   — must not preclude an RBI-regulated (India) bank_id from coexisting.
   Achieved structurally: Debit reads market-specific behavior (interchange
   rate, reporting format) from the *existing* `BankParameter.
   regulatory_regime`/`credit_reporting_format` cascade fields (already
   real, already per-`bank_id`) — no market-specific code branches, only
   config rows differ per bank.
4. **Account model**: fully separate schema (`cms_debit_accounts`), not a
   `cms_accounts` discriminator. Confirmed via direct schema inspection:
   `CMS.Account.credit_limit` is still `NOT NULL` today exactly as this
   doc originally found — a discriminator would need to weaken that
   guarantee for every existing credit account too. A separate schema
   avoids the "field exists, nothing enforces it" bug class this session
   has hit repeatedly (LMS, DPS, HCS all had it).

## 8. Additional schema finding (2026-07-26, before D1 starts)

`cta_cards.account_id` has a **real DB-level foreign key** to
`cms_accounts(account_id)` (confirmed via its migration, not assumed from
the Ecto schema alone — the Ecto schema itself has no FK annotation).
This means CTA's card entity cannot point at a `cms_debit_accounts` row
via the existing `account_id` column without either weakening that FK or
faking a placeholder `cms_accounts` row per debit account (both wrong).

**Resolution**: add a new nullable `debit_account_id` column to
`cta_cards` (own FK to `cms_debit_accounts`), with an application-level
"exactly one of `account_id`/`debit_account_id` is set" invariant in
`Card.changeset/2` — the same parallel-nullable-FK pattern this session
already used for `hcs_spending_controls.fleet_card_id` alongside
`employee_card_id` (Way4 Phase 1 item 3).

## 9. Phased Implementation Plan (confirmed, superseding §6's draft)

1. **D1 — Schema.** `CMS.DebitAccount` (own schema:
   `customer_id`/`sys_id`/`bank_id`/`logo_id`/`block_id` identity fields
   for the parameter cascade, `available_balance`, `status`, no
   `credit_limit`/`open_to_buy` at all). `cta_cards.debit_account_id`
   (nullable FK) + changeset invariant.
2. **D2 — Funding.** `CMS.DebitFunding` — deposit/load transaction types
   (`INTERNAL_TRANSFER`/`ADMIN_MANUAL`/`EXTERNAL_BANK_TRANSFER`/
   `CASH_DEPOSIT`), each posts a real `cms_ledger_entries` row (liability
   direction) and increments `available_balance`. External channels carry
   `channel` + `external_reference`, no live rail call (see §7.2).
3. **D3 — Authorization.** A debit-specific check — real-time balance
   debit on approval, not "pending until EOD." Given v1 has no OTB
   cascade to protect (a single `available_balance` number, not a
   multi-level credit line), a Horde-registered per-account GenServer
   (mirroring `AccountStateCoordinator`) would be new machinery for no
   real benefit at this volume — instead, a single atomic `UPDATE
   cms_debit_accounts SET available_balance = available_balance - $1
   WHERE debit_account_id = $2 AND available_balance >= $1 RETURNING
   available_balance` (optimistic decrement, Postgres MVCC handles the
   race, no explicit lock needed). Routed from `FAS.Authorization` via
   the same `product_type` cascade Avenza's (dead, unexercised) `"DEBIT"`
   branch already sketched — real BIN/LOGO config, this time actually
   reachable.
4. **D4 — GL + reporting.** Liability-side posting reuses
   `InternalGlPoster`/`cms_ledger_entries` as-is (direction is just which
   `gl_account_dr`/`gl_account_cr` codes are passed — no mechanism
   change needed, confirmed via `LedgerEntry`'s schema). EOD interest/
   statement jobs need no explicit exclusion — they're scoped to
   `cms_accounts` and a debit account never has a row there, so the
   separate-schema choice closes this whole risk class structurally,
   not via a defensive filter someone could forget.
5. **D5 — Card issuance + Ops UI.** `CTA.CardLifecycle.issue_new/2`
   pointed at a `DebitAccount` via the new `debit_account_id` column.
   Admin screens: debit account view/funding/balance history.
