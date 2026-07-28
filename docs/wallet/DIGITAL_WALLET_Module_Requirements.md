# Digital Wallet (Account/Ledger Product) — Feasibility & Requirements

**Status:** 📝 New-product planning doc (2026-07-28) — not started. This is
the Way4 parity plan's **Phase 2** requirements pass
(`docs/compare/Way4_Parity_Implementation_Plan.md` §2 "Phase 2 — Digital
channel absorption"), covering Digital Wallet, QR Payments, Instant
Payments, and Account-to-Account (A2A). **Do not confuse this with
`WALLET_Module_Requirements.md`** in this same folder — that doc is scoped
to network/scheme tokenization (Apple Pay/Google Pay via Visa VTS /
Mastercard MDES), a completely different capability that happens to share
the word "wallet." This doc is the wallet-app **account/ledger product**
port-in question the Way4 plan's Phase 2 actually refers to.

---

## 1. Purpose & Scope

A "digital wallet" here means a stored-value account product a customer
opens directly (not tied to a card the way Prepaid is) — check balance,
transfer to another wallet or a bank account, receive/pay via QR, top up,
cash out. It's the retail e-money product line, distinct from every other
product this codebase has built so far (Credit/Debit/Prepaid/Corporate/
Fleet), all of which are card-first. This is account-first, cards (if any)
are an appendage.

Four sub-capabilities, scoped together because they share the same account
substrate:

1. **Digital Wallet accounts** — open, hold balance, freeze/close.
2. **QR Payments** — generate/scan a QR code to receive or pay.
3. **Instant Payments** — a real-time payment rail (confirmed **not built
   anywhere**, see §3).
4. **Account-to-Account (A2A)** — wallet-to-bank-account transfers.

## 2. Ground truth: what's actually in the sibling `wallet-app` repo

A direct code investigation of `d:\momentPay\Products\E-VisionPlus\wallet-app\apps\`
(2026-07-28), not a doc-title guess, found:

| Capability | Real module(s) | Maturity |
|---|---|---|
| Account lifecycle | `wallet_accounts` (`Account`, `WalletProduct`, `SubWallet`, `CurrencyConfig`) | **Real & complete** |
| Ledger/GL | `wallet_ledger` (double-entry `Journal`/`Entry`/`PostingEngine`) + `wallet_gl` (external GL bridge) | **Real & complete**, more elaborate than this repo's own GL |
| Wallet-to-wallet transfer | `wallet_transfers` (`Transfer`, `sub_wallet_transfer.ex`) | **Real & complete** |
| QR payments | `wallet_transfers` (`QrIdentity`, `generate_money_request_qr.ex`, `pay_money_request_from_qr.ex`) + `wallet_web` (`qr_receive_live`, `merchant_qr_codes_live`) | **Real & complete** |
| A2A (wallet→bank) | `wallet_transfers` (`P2aTransfer` — IBAN/BIC/account/bank-code fields, `:initiated→:submitted→:completed/:failed→:compensated`) | **Real but partial** — full domain model + compensation saga, but the actual bank rail is a generic pluggable `provider` atom with no concrete adapter found |
| Instant payments / RTP | — | **Not found anywhere.** Searched for `instant_payment`/`rtp`/`immediate_payment`/named rails across all `apps/` — zero real hits (only coincidental matches inside vendored third-party JS). Confirmed aspirational, not partial. |
| Cardholder-facing UX | `wallet_web` (30+ LiveViews: dashboard, transfer, request-money, QR receive, merchant QR, cash-out, sub-wallets, statements, cards, KYC/onboarding, disputes, loans, insurance, rewards) | **Real & complete** as a customer app |
| KYC/limits tiering | `wallet_kyc` + `wallet_compliance` — step-up KYC triggered specifically by a tier-cap breach (`WalletKyc.Request.wallet_product_id`, moduledoc: "set only for a step-up submission started from a specific wallet product") | **Real but partial** — the step-up-on-breach linkage is real and specific; no separate named regulator-tier taxonomy beyond `:standard/:premium/:business` |
| Limits & fees | `wallet_limits_fees` (`LimitPolicy` per `{tier, currency}`, flat daily/monthly/txn caps + `flat_fee + pct*amount` clamped fee calc) | Real, but flatter/simpler than this repo's own ParameterEngine cascade |

Full research report is preserved in this session's transcript; the table
above is the load-bearing summary for the decisions in §4.

## 3. The one real, hard, external gap: Instant Payments

Unlike everything else in this doc, Instant Payments isn't a
port-vs-rebuild question — it's genuinely unbuilt in both repos and
requires an actual rail/vendor decision (which real-time payment network,
which market, whose API) before any scoping is meaningful. This is grouped
with QR/A2A in the Way4 plan provisionally; treat it as its own,
later-sequenced sub-item, not a blocker for starting Digital Wallet
accounts, wallet-to-wallet transfer, or QR.

## 4. Port-in vs. rebuild-native — decided per capability

Applying the "best implementation wins, one model of record" principle the
Way4 plan calls for, **and** the directly-relevant precedent already set
for Prepaid (`Way4_Phase1_Card_Portfolio_Tracker.md`'s sequencing
decision: wallet-app's own `wallet_accounts`/`wallet_ledger` were found
real and mature for Prepaid too, but the verdict was still **"build
native, don't port"** — because depending on the `wallet_*` app chain
contradicts this repo's own platform-of-record principle of zero
dependency on the sibling repo, and because introducing a second ledger
system would split "model of record" between `wallet_ledger`'s
double-entry journals and this repo's own `cms_ledger_entries`/
`InternalGlPoster`, which is already the real ledger of record for every
other product's clearing/settlement path).

**That precedent applies here with the same force, for the same reason —
this doc does not reverse it.** The recommendation below is: build
Digital Wallet natively on the `cms_accounts` spine, reusing
`wallet_accounts`/`wallet_ledger`/`wallet_transfers` as **design
reference**, not code to port.

| Capability | Verdict | Reasoning |
|---|---|---|
| Account entity | **Rebuild native** — new `account_type: "WALLET"` value on `CMS.Account`, same pattern this session's HCS Employee Card work just proved out (an `EMPLOYEE_CARD`-typed row reuses `cms_accounts`, `BlockCodeHistory`, `NonMonetaryEvent`, `CTA.CardLifecycle` entirely unchanged) | Keeps one account table, one block/audit-trail mechanism, no new parallel schema |
| Multi-currency wallet UX | **Rebuild native, informed by wallet-app's real pattern** — `wallet_accounts`' actual design is *not* a multi-currency balance on one row; it's a `WalletProduct` container holding N single-currency `SubWallet`s. This is directly compatible with this repo's own ADR-C4 (`CMS.Account` stays single-currency) without reversing it — build the "product" grouping as a new thin concept over multiple single-currency `cms_accounts` rows, same relationship shape `HCS.Company`→`EmployeeCard` already uses. | **This materially informs Way4 plan §3 Decision 2** — multi-currency does not require reversing ADR-C4; a real, tested implementation of the exact same requirement achieves it via composition instead. Worth taking back to that decision explicitly. |
| Ledger/balance posting | **Rebuild native on `InternalGlPoster`**, adopt `wallet_ledger.PostingEngine`'s *design* (idempotent by `reference_id`, balanced-debit/credit invariant validated before commit, freeze-aware rejection) as new `post_wallet_*` functions alongside the existing `post_debit_*`/`post_prepaid_*` ones | `InternalGlPoster`/`cms_ledger_entries` is already this repo's real ledger of record, integrated with TRAMS clearing for every other product. A second, parallel double-entry engine (`wallet_ledger`) would recreate exactly the "two ledgers, which one is real" split-brain this session's own CU-1 work (Unified Card Master) and the Phase 1 research note ("`cms_ledger_entries`/`InternalGlPoster` IS the real TRAMS ledger of record, not `WalletLedger`") already closed once |
| Wallet-to-wallet transfer | **Rebuild native**, `Transfer`'s state shape (`:initiated→:reserved→:completed/:failed`, idempotency key) is a good reference; the actual move is two `InternalGlPoster` postings (debit sender, credit receiver) inside one `Repo.transaction`, same shape `PrepaidLedger.consume_active_loads/2`/Debit's own adjustment posting already use | No new balance-movement primitive needed — this repo already has the atomic dual-posting pattern proven twice today (Debit/Prepaid Adjustments) |
| QR payments | **Rebuild native**, `QrIdentity`'s wire format (`WAL\|v1\|account_id\|currency\|amount\|label\|checksum`, SHA-256 checksum) is a clean, self-contained, zero-dependency design worth reusing *as a pattern* — no conflicting architecture in this repo to reconcile against | This is the cleanest "port the idea, not the code" case in this whole doc — genuinely new capability, no ledger-of-record conflict, no `wallet_*` dependency needed at all |
| A2A (wallet→bank) | **Design together, build later** — `P2aTransfer`'s domain shape (destination IBAN/BIC/account/bank-code fields, `:initiated→:submitted→:completed/:failed→:compensated`, compensation-on-failure) is worth adopting directly since it's genuinely well-designed and rail-agnostic; the actual bank-rail integration is unbuilt in *both* repos (`provider` is a bare atom, no concrete adapter anywhere) | Not blocked on a port-vs-rebuild question — blocked on the same kind of external vendor/rail decision as Instant Payments, just less totally-absent (the domain model exists) |
| Instant Payments | **Not scoped yet** | See §3 — needs a rail decision first, unrelated to anything else in this table |
| Step-up KYC on limit breach | **Rebuild native, adopt the pattern** — a new event type on `CMS.NonMonetaryEvent` (`wallet_limit_step_up_triggered`) firing when a wallet transfer/load would breach the current tier's cap, routed into a step-up KYC flow on `Shared.Customer` | `Shared.Customer.kyc_status` already exists; this needs a *trigger*, not a new customer model — the `wallet_kyc` step-up linkage is the piece genuinely missing here |
| Limits & fees | **No build needed — this repo's existing mechanism already wins** | `wallet_limits_fees`' flat `{tier, currency}` lookup is *simpler* than the SYS→BANK→LOGO→BLOCK cascade this repo already has; add a WALLET-appropriate LOGO/BLOCK config level and reuse `ParameterEngine` unchanged, consistent with the Way4 plan's own explicit instruction not to reintroduce a `DebitAccountConfig`/`PrepaidProgram`-style parallel config object |
| Cardholder-facing UX (`wallet_web`'s 30+ LiveViews) | **Rebuild native, do not port Phoenix code as-is** | This repo's admin console (`VmuCoreWeb.Live.Admin.*`) and any future cardholder-facing surface would need their own UI conventions/auth model (this session's own ASM/session work, not `wallet_web`'s); the LiveView *feature list* (dashboard, transfer, QR receive, statements, sub-wallets) is the useful artifact, not the markup |

## 5. Net-New Build Required (net of §4's "no build needed" rows)

| Area | What's needed |
|---|---|
| `CMS.Account` extension | `account_type: "WALLET"` (reuses the account_type field/EOD-exclusion fixed for HCS this session — confirm the EOD `account_type == "CREDIT"` filter is correct to also exclude WALLET, since a wallet balance never accrues interest either) |
| Wallet Product / grouping concept | New thin schema linking N single-currency `cms_accounts` rows under one customer-facing "wallet" — the multi-currency UX layer from §4 |
| `InternalGlPoster` extension | New `post_wallet_load/*`, `post_wallet_transfer_out/*`, `post_wallet_transfer_in/*`, `post_wallet_fee/*` functions, idempotent-by-reference_id, following the exact shape of the existing `post_debit_*`/`post_prepaid_*` functions |
| Transfer command | New `WalletTransferCommand` — atomic dual-posting (debit sender / credit receiver) inside one `Repo.transaction`, wallet-to-wallet only for v1 |
| QR identity | New module implementing `wallet_transfers.QrIdentity`'s wire-format pattern, generate + parse + checksum validate, targeting `cms_accounts`-backed wallet accounts |
| Step-up KYC trigger | New `NonMonetaryEvent` type + a check in the transfer/load command path comparing against the wallet's tier cap |
| Wallet-appropriate LOGO/BLOCK config | New `product_type: "WALLET"` LOGO row(s), no `ParameterEngine` code changes |
| Admin UI | Wallet account list/detail in the admin console, same wizard+tabs convention as Debit/Prepaid (`docs/compare/Card_Products_UX_Parity_Tracker.md`) — Overview/Ledger History/Transfers/QR/History tabs is the natural shape |

## 6. Feature Inventory (draft — validate with product before build)

| FR | Feature |
|---|---|
| W001 | Open/freeze/close a WALLET-typed `cms_accounts` row |
| W002 | Wallet Product grouping — N single-currency wallet accounts under one customer-facing wallet |
| W003 | Wallet-to-wallet transfer, atomic dual-posting via `InternalGlPoster` |
| W004 | QR generation (receive) |
| W005 | QR payment (scan-and-pay, resolves to a wallet-to-wallet transfer) |
| W006 | Merchant-presented QR (fixed/variable amount, revoke/expire) — v2, after personal QR is proven |
| W007 | Load channels (cash/agent, bank transfer, card-to-wallet) |
| W008 | Step-up KYC trigger on tier-cap breach |
| W009 | Wallet-appropriate LOGO/BLOCK parameter config (limits, fees) |
| W010 | Admin ops UI (wizard + tabs, matching Debit/Prepaid convention) |
| W011 | A2A (wallet→bank) — domain model only until a rail is chosen |
| W012 | Instant Payments — blocked entirely on rail/vendor decision |

## 7. Phased Implementation Plan (high-level — refine before starting)

1. **Phase W1 — Account + ledger foundation.** `account_type: "WALLET"`,
   Wallet Product grouping, `InternalGlPoster` wallet posting functions.
   No transfer yet — this phase proves open/load/close end-to-end against
   real Postgres, same discipline every other phase this session used.
2. **Phase W2 — Wallet-to-wallet transfer.** `WalletTransferCommand`,
   atomic dual-posting, real-data test proving a transfer can't create or
   destroy money (balanced-invariant check, matching `wallet_ledger`'s own
   design).
3. **Phase W3 — QR (personal, receive + pay).** New QR identity module,
   wired to Phase W2's transfer command.
4. **Phase W4 — Admin ops UI.** Wizard + tabs, same convention as Debit/
   Prepaid/HCS from this session's Card Products UX Parity work.
5. **Phase W5 — Step-up KYC + limits/fees config.**
6. **Phase W6+ — A2A and Instant Payments**, each gated on its own
   external rail/vendor decision, not started until that decision lands.
   Merchant-presented QR (W006) also fits here — genuinely v2 relative to
   personal QR.

## 8. Open Questions (need product/business input before W1 starts)

1. **Confirm the multi-currency finding lands.** §4's Wallet-Product/
   sub-account composition pattern is offered as the answer to Way4 plan
   §3 Decision 2 — does this resolve that decision, or is there a real
   requirement (e.g. a single balance genuinely denominated in a currency
   chosen at transaction time) that composition can't satisfy?
2. **Load channels for v1** — which of cash/agent, bank transfer,
   card-to-wallet are actually needed at launch vs. later?
3. **A2A rail** — same shape of question as tokenization's VTS/MDES
   choice: which bank-transfer rail/provider, which market, before §7
   Phase W6 can be scoped for real.
4. **Instant Payments rail** — needs its own vendor/market decision,
   entirely separate from A2A's.
5. **Merchant-presented QR** — is a merchant-side flow actually in scope
   for this phase, or does merchant QR belong with
   `MerchantManagementSystem` instead (the way merchant onboarding/KYB
   already does, per the Way4 plan's own MBS scope resolution)? Worth
   deciding before W006 rather than assuming it's a vmu_core admin-console
   feature.
