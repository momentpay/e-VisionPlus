# Card Products UX Parity — Debit / Prepaid / HCS Corporate vs. Credit

**Status:** Planning — phases not yet started
**Date:** 2026-07-28
**Trigger:** User screenshots showing Credit's account-opening wizard
(Customer → Product → Card & Credit → Config → Review) and 6-tab detail
view (Overview/Balances/Cards/Statements/History/Plans) next to Debit's
flat single-form creation (raw SYS/BANK/LOGO/BLOCK ID text fields, no
tabs at all in detail). Same gap applies to Prepaid and HCS Corporate.

**Guiding principle** (from Avenza's own
`docs/party-product-tab-taxonomy.md`, written for exactly this situation):

> A product's sub-tab set is a function of what that product's own
> lifecycle and data model actually generates — not a copy of whichever
> product got built first... an honest gap beats an invented one.

This tracker does **not** propose copying Credit's 6 tabs onto every
product. Debit has no credit limit, no billing cycle, no installment
plans — a "Plans" tab would be fake. Each product's tab set below is
derived from what its own schema and backend context modules actually
support today, with real gaps called out explicitly rather than papered
over.

---

## 1. Current-state audit

| | Credit (`AccountComponent`) | Debit (`DebitComponent`) | Prepaid (`PrepaidComponent`) | HCS Corporate (`HcsComponent`) |
|---|---|---|---|---|
| **Creation flow** | 5-step wizard: Customer (search+select) → Product (Bank/Logo/Block cascading dropdowns) → Card & Credit → Config → Review | Flat single form — 6 raw text inputs (SYS ID/Bank ID/Logo ID/Block ID typed by hand, no dropdowns, no validation against real parameter records) | Same flat form as Debit | Flat single form for Company; **Employee Card creation has zero UI** (backend `CompanyOnboarding.add_employee_card/3` exists, never called from any component) |
| **Detail view** | 6 tabs: Overview / Balances / Cards / Statements / History / Plans | None — single flat page (Balance card + Funding History table + Cards table, all stacked) | Same flat single-page shape as Debit | None — single flat page (Facility fields + Employee Cards list with **no actions**, stacked) |
| **Card lifecycle actions** | Issue / Reveal (virtual) / Activate / Block / Unblock / Replace / Renew / Channel controls (8) | Issue / Activate / Block / Unblock (4) — no Replace, no Renew, no channel controls | Same 4 as Debit | Fleet cards: issue (via vehicle flow) — no activate/block/unblock UI. Employee cards: **no lifecycle actions of any kind** |
| **Financial actions** | Account block/unblock (5 reason codes), 5 non-monetary event types (address/phone/email/cycle/name change), Permanent limit change, Temp limit (4-eyes), Fee waiver (4-eyes), Financial adjustment (4-eyes, credit or debit direction), Supplementary card link | Fund only — no correction/adjustment capability, no account-level block | Load only — `PrepaidLedgerEntry` already declares an `ADJUSTMENT` entry_type at the schema level, but nothing in the UI (or context layer) ever creates one | Facility limit change (real 4-eyes-style approval workflow, already built) |
| **Sub-account lifecycle** | N/A (Supplementary Card is the closest analog — already wired) | N/A | N/A | Fleet: vehicle add, driver assign/unassign — wired. Employee: **entirely unwired**, this is the single biggest gap in the whole audit |

---

## 2. Target per-product tab taxonomy

### Debit (`CMS.DebitAccount` — single balance, no limit/OTB, no cycle)

| Tab | Backing data | Status |
|---|---|---|
| Overview | balance, status, opened/closed dates | Exists today (flat) → becomes tab 1 |
| Funding History | `DebitFunding` rows | Exists today (flat table) → becomes tab 2 |
| Cards | existing card list + issue/activate/block/unblock | Exists today (flat) → becomes tab 3 |
| Adjustments *(new)* | manual correcting entries — mirrors Credit's Financial Adjustment 4-eyes shape | **Real gap** — no backend or UI today |

Deliberately **not** building: Statements (no billing cycle), Plans (no
installment concept), non-monetary-event History (address/phone/email
changes are Customer-level, already handled on the Customer page, not a
Debit-account concern).

### Prepaid (`CMS.PrepaidAccount` — ledger-based: LOAD/SPEND/FEE/EXPIRE/REFUND/ADJUSTMENT)

| Tab | Backing data | Status |
|---|---|---|
| Overview | derived balance (`PrepaidLedger.balance/1`), status | Exists today (flat) → becomes tab 1 |
| Ledger | `PrepaidLedgerEntry` full history — genuinely richer than Debit's funding list, this *is* Prepaid's real "Statements" equivalent | Exists today (flat table, LOAD only shown) → becomes tab 2, extend to show all entry types |
| Cards | same shape as Debit | Exists today (flat) → becomes tab 3 |
| Adjustments | expose the already-declared `ADJUSTMENT` entry_type | **Small gap** — schema supports it, context/UI don't yet |

Deliberately not building: Statements/Plans/temp-limit (no credit line
concept applies to a stored-value product).

### HCS Corporate (`HCS.Company`/`EmployeeCard`/`FleetCard`)

| Tab | Backing data | Status |
|---|---|---|
| Facility Overview | existing company fields | Exists today (flat) → becomes tab 1 |
| Employee Cards | list + **new**: create (`CompanyOnboarding.add_employee_card/3`, already exists) + activate/block/unblock (new backend work — `EmployeeCard.status` exists but no lifecycle functions call it yet) | **Real gap — biggest item in this whole plan** |
| Fleet Cards | vehicle assign, driver assign/unassign, card issue — already exists, currently interleaved into the flat page | Exists today (flat) → becomes tab 3 |
| Spending Controls | already exists as an action panel | Exists today → becomes tab 4 |
| Reports | fleet spend report generation — already exists | Exists today → becomes tab 5 |

Facility Limit Change stays as an action (like Credit's Temp Limit),
not a tab — it's a single in-flight approval, not a browsable history
yet (no `FacilityLimitChangeHistory` table).

---

## 3. Target creation flow (wizard, not flat form)

Same 3-part shape as Credit's wizard, adapted per product — the real,
separate bug today is that Debit/Prepaid make the operator **type raw
SYS/BANK/LOGO/BLOCK IDs by hand** with no validation, while Credit's
wizard cascades real `BankParameter`/`LogoParameter`/`BlockParameter`
records through dropdowns.

- **Debit / Prepaid**: Customer (search+select, reuse Credit's wizard
  step 1 pattern) → Product (Bank/Logo/Block cascading dropdowns,
  reuse Credit's wizard step 2 pattern) → Review
- **HCS Company**: Owner Customer → Facility Config (credit limit,
  liability model, billing cycle) → Review
- **HCS Employee Card**: Select Company → Employee Customer → Card
  Config (individual limit, card type) → Review *(net-new — no wizard
  exists today because no creation flow exists today)*
- **HCS Fleet Card**: Select Company → Vehicle → Card Config → Review
  *(currently a flat action-panel form, wizard-izing is optional
  polish, lower priority than Employee Cards since it already works)*

---

## 4. Phases

| Phase | Scope | Why this order |
|---|---|---|
| **Phase 1 — Debit** | Wizard-based account creation (Customer → Product dropdowns → Review); tab-based detail (Overview/Funding History/Cards/Adjustments); build the Adjustments capability (context + UI) | Smallest, most self-contained product; the concrete pain point in the screenshots; establishes the reusable wizard-step and tab-bar pattern the rest of this plan reuses |
| **Phase 2 — Prepaid** | Same shape as Phase 1, applied to Prepaid | Structurally near-identical to Debit once Phase 1's pattern exists — should move fast; extends the Ledger tab to show all entry types, wires the existing `ADJUSTMENT` entry_type into the UI |
| **Phase 3 — HCS Employee Cards** | Wire `add_employee_card/3` into a real creation wizard; add the entirely-missing activate/block/unblock lifecycle (new backend functions + UI); Employee Cards becomes its own tab | Biggest real gap in the whole audit — currently zero UI for something the backend already half-supports |
| **Phase 4 — HCS Corporate polish** | Reorganize the existing Fleet Cards/Spending Controls/Reports content into the same tab convention as Phases 1–3; optionally wizard-ize Fleet Card issuance and Company creation | Lowest urgency — everything in this phase already works today, this is pure consistency/polish, not closing a functional gap |

Each phase: real Postgres verification (no mocked DB), a full-suite
regression check against the established baseline (10 known
pre-existing failures) before commit, and its own commit(s) following
the "stage only what the phase touched" discipline already used
throughout this project.

---

## 5. Open questions before starting

1. **Phase order** — proceed Debit → Prepaid → HCS Employee → HCS
   polish as above, or reprioritize (e.g. HCS Employee Cards first,
   since it's a full functional gap rather than a UX upgrade)?
2. **Debit/Prepaid Adjustments** — confirm the 4-eyes maker/checker
   pattern (like Credit's Temp Limit/Fee Waiver/Financial Adjustment)
   is the right shape for this, rather than a single-operator action.
3. **HCS Employee Card block/unblock** — should this reuse
   `CTA.CardLifecycle.block/3`/`unblock/2` directly (the card is
   already a real `cta_cards` row via the unified card master), or
   does Employee Card status need its own state machine independent
   of the card's own status? (Fleet cards already went through this
   question during Way4 Phase 0 — worth checking that precedent.)
