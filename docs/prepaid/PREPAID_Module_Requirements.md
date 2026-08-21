# Prepaid Cards — Product Feasibility & Requirements

**Status:** 📝 New-product planning doc (2026-07-11) — not started. Written after
confirming with the team that no prepaid card issuing exists in the current
system: `LogoParameter.product_type` accepts `"PREPAID"` as a stored value,
but it is pure reference metadata with zero behavioral effect anywhere.

---

## 1. Purpose & Scope

A prepaid card holds **stored value the cardholder has already loaded** —
there is no credit line and, unlike a debit card, often no linked deposit
account at all: the card's balance *is* the account. Spend draws the stored
value down directly; there's no settlement against a separate balance
elsewhere.

**Boundary test vs. Debit** (see `../debit/DEBIT_Module_Requirements.md`):
debit draws against a real bank deposit account that exists independently of
the card; prepaid's balance is self-contained on the instrument/program
itself. This distinction matters for KYC tiering (many markets allow
lighter-KYC anonymous/gift prepaid below a value threshold, which a debit
account — tied to a full bank account — never would) and for regulatory
classification (prepaid is frequently regulated as "stored value" or
"e-money," a different license category from deposit-taking).

## 2. Where This Sits Relative to the Current System

Structurally very close to Debit's gap (see that doc's §2 for the detailed
`credit_limit`-required / `AccountStateCoordinator` OTB-coupling argument —
it applies identically here: prepaid needs a balance-sufficiency check, not
a credit-line check, and the account schema's required `credit_limit` field
doesn't fit a stored-value instrument). Prepaid adds two further departures
from anything in this codebase today:

- **No revolving relationship at all** — not even the "linked deposit
  account" debit has. The card program itself is the ledger.
- **KYC tiering** — anonymous/low-KYC prepaid (gift-card style, load-and-spend,
  capped value) vs. full-KYC reloadable prepaid are typically two different
  products with different regulatory limits. `Shared.Customer` currently
  assumes every cardholder is a fully-KYC'd individual/corporate CIF record
  (`kyc_status` PENDING/VERIFIED/REJECTED) — there's no concept of an
  anonymous or lightly-identified cardholder anywhere in the schema.

## 3. What's Genuinely Reusable

- **CTA's card entity + lifecycle** — issuance, activation, block/replace,
  channel controls are plastic-level concerns, identical regardless of the
  value model behind the card.
- **SYS→BANK→LOGO→BLOCK parameter cascade** — a prepaid LOGO/program fits
  the existing hierarchy without changing the cascade mechanism.
- **FAS switch/HSM/PIN infrastructure** — transport/security layer,
  unaffected by the account model behind it.
- **ASM, Module Configuration Framework** — fully reusable.
- **LMS's points-ledger pattern** is a useful architectural precedent, not
  code to reuse directly: `LMS.PointsLedger` is already an append-only
  ledger of value in/out with a derived balance — the same shape a prepaid
  stored-value ledger needs (see LMS-P1's bug this session, where deriving
  the balance from the ledger rather than maintaining an independently
  mutated counter was the fix — worth designing prepaid's ledger this way
  from day one rather than repeating that mistake).

**⚠ Cross-repo finding, 2026-07-11 — this substantially already exists.**
The sibling `wallet-app` repo has real, tested `wallet_accounts` (account
open/freeze/tier lifecycle) + `wallet_ledger` (genuine double-entry engine —
balanced invariant, idempotent via reference_id, reversal support,
freeze-aware) + `wallet_cards` (card issuance against the account, BIN
validation, PAN tokenization, balance-drift reconciliation). This is, in
substance, most of §3-4 below already built and tested — not a precedent to
copy the *shape* of, an implementation to extend. **Recommend building
Prepaid in wallet-app on top of this, not from scratch in vmu_core.** The
KYC-tiering question (§7.1) is the main genuinely-open piece.

## 4. Net-New Build Required

| Area | What's needed |
|---|---|
| Account/ledger model | A stored-value ledger (load/spend/fee/expire entries with a derived balance — see LMS precedent above), not a `credit_limit`-based account |
| Load channels | Cash load (agent/kiosk), card-to-card transfer, bank transfer, payroll/corporate bulk load |
| KYC tiering | A lighter-KYC path for anonymous/low-value prepaid, separate from `Shared.Customer`'s current full-KYC-only model |
| Authorization | Balance-sufficiency check (parallel to Debit's, likely shareable with it — both are "check a real balance," not "check a credit line") |
| Expiry | Stored-value products commonly have use-it-or-lose-it expiry/dormancy rules (distinct from CTA's plastic-expiry, which is about the physical card, not the money) |
| Regulatory | E-money/stored-value licensing treatment differs from card-issuing; reporting obligations likely differ from both credit and debit |

## 5. Feature Inventory (draft — validate with product before build)

| FR | Feature |
|---|---|
| 001 | Program/card issuance without requiring a full CIF customer record (KYC-tiered) |
| 002 | Stored-value ledger: load, spend, fee, expiry, refund entries — derived balance, not a mutated counter |
| 003 | Load channels: cash/agent, bank transfer, card-to-card, bulk corporate/payroll load |
| 004 | Balance-sufficiency authorization (no credit line) |
| 005 | Value expiry / dormancy fee rules |
| 006 | KYC step-up: upgrade an anonymous/gift card to a full reloadable card by completing KYC later |
| 007 | Corporate bulk-issuance (payroll cards, incentive/gift programs) — overlaps HCS's bulk-issuance concept but for stored value, not credit |
| 008 | Refund-to-source / cash-out at program end-of-life |
| 009 | Regulatory stored-value reporting |

## 6. Phased Implementation Plan (high-level — refine before starting)

1. **Phase P1 — Ledger + account model.** Stored-value ledger schema
   (load/spend/fee/expiry), derived-balance query — apply the LMS lesson:
   build the balance as a ledger sum from day one, not an independently
   mutated field that can drift out of sync with reality.
2. **Phase P2 — KYC tiering.** Decide and build the lighter-KYC cardholder
   path (likely a new, simpler identity record distinct from full
   `Shared.Customer`, or an explicit tier field on it) before load channels
   depend on it.
3. **Phase P3 — Load channels.** Start with the simplest (internal
   transfer/bulk corporate load) before cash-agent/kiosk integrations, which
   need a real external partner.
4. **Phase P4 — Card issuance wiring + authorization.** Point CTA's card
   entity at prepaid accounts; build the balance-sufficiency auth check
   (share design with Debit's — same shape of problem).
5. **Phase P5 — Expiry/dormancy + regulatory reporting.**
6. **Phase P6 — Ops UI.**

## 7. Open Questions — ANSWERED 2026-07-27 (Way4 parity plan Phase 1 item 5)

1. **KYC tiering**: No — full-KYC reloadable only. Every prepaid cardholder
   is a normal `Shared.Customer` CIF record, same as every other product.
   No lighter-weight identity model built; a step-up/anonymous tier can be
   added later without reworking the ledger.
2. **Load channels**: internal transfer **and** external bank transfer/cash
   deposit, modeled as real records with a channel tag + reference — no
   live rail call (none exists in this codebase). Same pattern already
   shipped for Debit's `DebitFunding.channel`.
3. **Market**: same as Debit — config-driven via the existing
   `BankParameter.regulatory_regime` cascade, not hardcoded to one market.
4. **Shared model with Debit, now that Debit is built?** No — kept
   deliberately separate. Debit's `available_balance` is a simple mutated
   counter (correct for it: no per-unit expiry concept, real-time
   auth-critical, proven race-safe under real concurrent load). Prepaid
   needs **per-load expiry/dormancy** (FR-005) — you cannot expire "part
   of a flat counter," only a specific load's remaining, unexpired value —
   so it needs a genuine ledger, not a counter. Building this required
   `[[LMS.PointsLedger]]`-style design was flagged as the right precedent
   in this doc's original §3, and confirmed again now that a full v1 KYC/
   load-channel scope is settled.

## 8. Confirmed design: ledger-derived balance with per-load expiry

`CMS.PrepaidLedgerEntry` — one row per LOAD, with its own mutable
`remaining_amount` (starts equal to `amount`, decreases only as that
specific load is consumed by spend or by expiry) — the same "ledger row
itself reflects partial consumption, no separate mutated balance field"
shape `LMS.PointsLedger.active_balance/1` already uses (and whose
absence was the real LMS-P1 bug this session found and fixed).

- `balance/1` = `sum(remaining_amount)` across `ACTIVE`, unexpired LOAD
  rows for the account. Always derived, never stored.
- `spend/2` — inside one DB transaction, locks (`FOR UPDATE`) the
  account's ACTIVE LOAD rows ordered `expiry_date ASC NULLS LAST,
  inserted_at ASC` (soonest-expiring first — standard stored-value FIFO),
  walks them decrementing `remaining_amount` until the requested amount
  is covered (declining/rolling back if total available is insufficient),
  and inserts one `SPEND` ledger row recording which loads it drew from
  and how much (`consumed_from: [%{load_entry_id:, amount:}, ...]`, a
  JSONB breakdown field — same convention `AuthorizationRecord.
  decision_path` already uses for this shape of "audit breakdown" data).
- `credit/2` (reversal/release) reads the `SPEND` row's `consumed_from`
  breakdown and restores each contributing load's `remaining_amount` by
  its recorded portion — never a flat "add it back to whichever load is
  active now," since that load may have since expired or a different one
  may have become the FIFO head.
- An expiry sweep (own Oban job, Phase P5) converts an expired LOAD row's
  remaining `remaining_amount` into an `EXPIRE` ledger row and zeroes it.

## 9. Phased Implementation Plan (confirmed, supersedes §6's draft)

1. **P1 — Ledger + account model.** `CMS.PrepaidAccount` (own identity
   fields for the parameter cascade — no `available_balance` field at
   all, unlike `DebitAccount`), `CMS.PrepaidLedgerEntry` (LOAD/SPEND/FEE/
   EXPIRE/REFUND/ADJUSTMENT types, `remaining_amount` on LOAD rows,
   `consumed_from` breakdown on SPEND rows), `CMS.PrepaidLedger` context
   (`balance/1`, `load/2`, `spend/2`, `credit/2`).
2. **P2 — Card issuance wiring.** `CTA.CardLifecycle.issue_new_prepaid/2`
   (mirrors Debit's D5 `issue_new_debit/2`), `cta_cards.prepaid_account_id`
   (third nullable FK alongside `account_id`/`debit_account_id` —
   `Card.changeset/2`'s "exactly one" invariant extends to three).
3. **P3 — Authorization.** Routes from `FAS.Authorization` via the same
   `product_type` cascade Debit's D3 already wired (`"PREPAID"` branch
   alongside `"DEBIT"`), calling `PrepaidLedger.spend/2` instead of a
   flat balance decrement.
4. **P4 — Settlement posting.** Same shape as Debit's D4 — a
   `SettlementPostingAdapter` branch that posts the permanent GL entry
   (liability-direction, new codes) and does NOT re-touch the ledger
   (the auth-time `spend/2` call already made the real value movement).
5. **P5 — Expiry/dormancy sweep + ops UI.**
