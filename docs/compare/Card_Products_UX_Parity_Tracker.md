# Card Products UX Parity — Debit / Prepaid / HCS Corporate vs. Credit

**Status:** Phase 1 (Debit) done — commits `e741e63`/`3c5ec57`/`0a4cd35`. Phase 2 (Prepaid) done — commit `7f83e75`. **Scope corrected 2026-07-28b — see §6.** Phase 1e (Debit retrofit) done — backend commit `84d1156`, UI commit `8c8a85d`. Phase 2d (Prepaid retrofit) done — commit `7fa5f5d`. Phase 3 (HCS Employee Cards) done — see §7 for the "extend the model" architecture decision and the account_type EOD bug it surfaced. Phase 4 (HCS Corporate polish) next.

## §7 — Phase 3 (HCS Employee Cards): "extend the model" decision

Employee Card had **zero admin UI at all** (a read-only table row, no
create/view/manage), and architecturally didn't map onto the Debit/
Prepaid 6-item template the way Debit/Prepaid mapped onto each other —
no `CTA.Card` (no PAN), no `Shared.Customer` link, just a company-scoped
limit-tracking sub-account (`HCS.EmployeeCard` + a `CMS.Account` row).
User chose **"extend the model first"**: give Employee Card a real
`CTA.Card` and a real individual `Shared.Customer`, so all 6 template
items apply uniformly instead of skipping 4 of them as "not applicable."

**This turned out to require far less new backend work than expected**,
because `add_employee_card/3` already inserts its sub-account into
`cms_accounts` — the exact same table Credit uses — so `CTA.
CardLifecycle.issue_new/2`, `CMS.BlockCodeHistory`, and `CMS.
NonMonetaryEvent` all already worked against an Employee Card's
`employee_account_id` completely unchanged. No new Employee-Card-specific
tables were needed (unlike Debit/Prepaid's Phase 1e/2d, which each
needed two new tables) — the only new module is `HCS.EmployeeCardCommand`
for the two things that DO differ from Credit: `apply_block`/`remove_block`
cascade to three places, not one (`cms_accounts.block_code`, `HCS.
EmployeeCard.status` — confirmed by reading `LimitController.
get_active_card/1` that HCS's own spend-limit enforcement gates on
this field, NOT `block_code` — and any real issued `CTA.Card`), and
`change_limit/4` reuses `add_employee_card/3`'s exact company-pool math
so a limit *change* re-validates against the facility the same way a
new card issuance does.

**Real pre-existing bug found while scoping this** (see `CMS.Account`'s
`account_type` field, migration `20260728000006`, commit `9281604`):
`account_type: "EMPLOYEE_CARD"`/`"CORPORATE_PARENT"` was always passed
into `Account.changeset/2` by `CompanyOnboarding` but silently dropped
— not a schema field — so every HCS sub-account was indistinguishable
from a real credit account to `EodSchedulerJob`/`LockAccountsJob`,
which sweep by `cycle_code`/`account_status` with no product-type
filter. Fixed by persisting the field (backfilled "CREDIT" for all
pre-existing rows) and filtering both EOD jobs to `account_type ==
"CREDIT"`. This was a **blocking prerequisite**, not a nice-to-have —
issuing a real `CTA.Card` against an unfixed account would have made
it fully transactable too, compounding the bug rather than just
exposing a UI gap.

Deliberately excluded, consistent with the domain: Adjustments (no
separate ledger exists for Employee Card the way Debit/Prepaid have —
`individual_limit`/`daily_spend` already track spend directly, no
manual balance-correction mechanism exists to expose). Company-level
KYC (`HCS.Company.kyc_status`) is untouched — Phase 3's KYC action
targets the *individual employee's* own `Shared.Customer.kyc_status`,
a distinct, smaller-scope concept.

Two real bugs found live while building the UI: (1) notice messages
containing an apostrophe (`"company's"`) never matched test assertions
`=~`-checking the same literal string — HEEx auto-escapes `'` to
`&#39;` in interpolated text — fixed by rephrasing to avoid possessives/
contractions in all new user-facing messages, the same convention this
codebase's other messages already followed without anyone having
written it down. (2) `load_employee_detail/2` unconditionally reset
`employee_detail_tab` to 1 on every call, including reloads after
in-tab actions (issuing a card while on the Cards tab silently bounced
the view back to Overview) — fixed by only setting the tab explicitly
at the two "fresh navigation" call sites (`view_employee`, a brand-new
card's wizard save), not inside the shared loader — same convention
Debit/Prepaid's own `load_detail/2` already uses.
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
| Overview | balance, status, opened/closed dates | Done |
| Funding History | `DebitFunding` rows | Done |
| Cards | card list + issue/activate/block/unblock (+ channel controls, + SUPPLEMENTARY option — Phase 1e) | Done, extended in Phase 1e |
| Adjustments | manual correcting entries, 4-eyes | Done |
| History *(new, Phase 1e)* | combined Block History + Non-Monetary Event history, mirroring Credit's History tab | **Real gap**, per §6 |

Action toolbar above the tabs (mirroring Credit's own layout —
identity/KYC row + account-action row), **new in Phase 1e**: Apply
Block, Address/Phone/Email/Emboss Name change, Change Limits (velocity,
store+display only — see §6 item 2), KYC Verification Workflow
(Verify/Reject/Reset, advisory-only).

Still correctly not building: Statements (no billing cycle), Plans (no
installment concept) — genuinely tied to revolving credit, confirmed
in §6.

### Prepaid (`CMS.PrepaidAccount` — ledger-based: LOAD/SPEND/FEE/EXPIRE/REFUND/ADJUSTMENT)

| Tab | Backing data | Status |
|---|---|---|
| Overview | derived balance (`PrepaidLedger.balance/1`), status | Done |
| Ledger | `PrepaidLedgerEntry` full history — this *is* Prepaid's real "Statements" equivalent | Done |
| Cards | card list + issue/activate/block/unblock (+ channel controls, + SUPPLEMENTARY option — Phase 2d) | Done, extended in Phase 2d |
| Adjustments | 4-eyes, CREDIT/DEBIT direction | Done |
| History *(new, Phase 2d)* | combined Block History + Non-Monetary Event history | **Real gap**, per §6 |

Same new action toolbar as Debit's Phase 1e, own tables: Apply Block,
Address/Phone/Email/Emboss Name change, Change Limits (velocity,
store+display only), KYC Verification Workflow (advisory-only).

Still correctly not building: Statements/Plans/temp-limit — no credit
line concept applies to a stored-value product, confirmed in §6.

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
| **Phase 1 — Debit** ✅ | Wizard-based account creation (Customer → Product dropdowns → Review); tab-based detail (Overview/Funding History/Cards/Adjustments); build the Adjustments capability (context + UI) | Smallest, most self-contained product; the concrete pain point in the screenshots; establishes the reusable wizard-step and tab-bar pattern the rest of this plan reuses |
| **Phase 2 — Prepaid** ✅ | Same shape as Phase 1, applied to Prepaid | Structurally near-identical to Debit once Phase 1's pattern exists — should move fast; extends the Ledger tab to show all entry types, wires the existing `ADJUSTMENT` entry_type into the UI |
| **Phase 3 — HCS Employee Cards** | Wire `add_employee_card/3` into a real creation wizard; add the entirely-missing activate/block/unblock lifecycle (new backend functions + UI); Employee Cards becomes its own tab | Biggest real gap in the whole audit — currently zero UI for something the backend already half-supports |
| **Phase 4 — HCS Corporate polish** | Reorganize the existing Fleet Cards/Spending Controls/Reports content into the same tab convention as Phases 1–3; optionally wizard-ize Fleet Card issuance and Company creation | Lowest urgency — everything in this phase already works today, this is pure consistency/polish, not closing a functional gap |

Each phase: real Postgres verification (no mocked DB), a full-suite
regression check against the established baseline (10 known
pre-existing failures) before commit, and its own commit(s) following
the "stage only what the phase touched" discipline already used
throughout this project.

---

## 5. Decisions

1. **Phase order** — confirmed 2026-07-28: Debit → Prepaid → HCS
   Employee Cards → HCS Corporate polish, as laid out above.
2. **Debit/Prepaid Adjustments** — confirmed 2026-07-28: 4-eyes
   maker/checker, same pattern as Credit's Temp Limit/Fee Waiver/
   Financial Adjustment (`ASM.Authz.validate_checker/4`).
3. **HCS Employee Card block/unblock mechanism** — still open, to
   resolve during Phase 3: reuse `CTA.CardLifecycle.block/3`/
   `unblock/2` directly (the card is already a real `cta_cards` row via
   the unified card master), or does `EmployeeCard.status` need its own
   state machine independent of the card's own status? Check the Fleet
   Card precedent from Way4 Phase 0 before deciding.

---

## 6. Scope correction (2026-07-28b) — user pushback, confirmed right

User challenged §2's exclusions directly: "for credit — limit, address,
email, phone and other options of Credit are applicable then why not
for Debit and prepaid. I can have limit for transaction etc for debit
also." Re-examined every excluded item against the actual code (not
assumption) before responding — verified, not just reasoned about:

- `CMS.Account.velocity_limits` (JSONB daily count/amount caps per
  channel) exists on Credit; `DebitAccount`/`PrepaidAccount` have **no
  equivalent field at all**. Real gap — a debit card needs a daily
  ATM/POS cap same as anyone else's.
- `CMS.Account.block_code`/`block_reason`/`blocked_at` +
  `BlockCodeHistory` (account-level block, distinct from card-level
  block) exist on Credit only. Debit/Prepaid can only block the *card*
  today (`CardLifecycle.block/3`), never the *account* — no way to
  freeze the relationship independent of which plastic is blocked.
- `CTA.CardLifecycle.set_channel_controls/2` (ecom/ATM/contactless/
  intl toggles) is already card-generic (`Cards.set_channel_controls/2`
  has no product-specific logic) — just never wired into Debit's or
  Prepaid's admin UI. Cheap fix, not a design question.
- Supplementary cards: `Card.card_types()` already includes
  `SUPPLEMENTARY` generically and multiple cards can already share one
  `debit_account_id`/`prepaid_account_id` — Debit/Prepaid's story is
  *simpler* than Credit's (no separate-account "linking" mechanic
  needed, just issue a second card against the same account). The
  issue-card dropdown just never offered the option.
- Fee Waiver is correctly absent for now — blocked on no fee-*charging*
  mechanism existing for Debit/Prepaid yet (no `FEE` transaction code
  ever posted), not because the concept doesn't apply.
- Address/Phone/Email/Emboss Name: originally proposed moving these to
  the Customer page only, since `Shared.Customer` is the only place
  those fields actually live and Credit's own `NonMonetaryEvent`
  action updates the *customer* record while auditing it under the
  *account's* id. **User explicitly rejected this — wants each
  product's own copy of these actions too, KYC included** (consistent
  with the Koṣa domain-model discussion earlier — KYC tiers can
  genuinely differ per product, not just per customer).
- Statements (billing-cycle snapshot), Plans (EMI/installments), and
  the multi-bucket Balances tab remain correctly excluded — tied to
  revolving credit and interest accrual, which Debit/Prepaid
  structurally don't have. This part of §2 stands.

**Real technical constraint found before proposing the retrofit:**
`NonMonetaryEvent.account_id` and `BlockCodeHistory.account_id` both
carry a genuine **database-level** `references(:cms_accounts, ...)`
foreign key (not just Elixir typing) — confirmed by reading the actual
migrations, not assumed. They cannot be reused as-is for Debit/Prepaid;
inserting a `debit_account_id` would violate the FK. Rather than loosen
a working, tested constraint on Credit's own tables, Debit/Prepaid get
their **own parallel tables** — consistent with how Adjustments was
already built (separate `DebitAdjustment`/`PrepaidAdjustment`, not one
shared polymorphic table).

### Confirmed additional scope — same for Debit and Prepaid, own copies

1. **Account-level Block/Unblock** — new `block_code`/`block_reason`/
   `blocked_at` fields + a new `cms_{debit,prepaid}_block_history`
   table (own FK to that product's account table), mirroring
   `BlockCodeHistory`'s reason-code shape.
2. **Transaction/Velocity Limits** — new `velocity_limits` JSONB field
   on `DebitAccount`/`PrepaidAccount`, mirroring `CMS.Account`'s. Scope
   for this pass: **store + display + admin-editable**, not wired into
   the live authorization path — `AccountStateCoordinator.
   check_velocity/3` is Credit-only today and actually enforcing
   Debit/Prepaid velocity limits at auth time is a separate, larger
   change to `DebitAuthorization`/`PrepaidLedger.spend/3` (flagged, not
   silently taken on here).
3. **Channel Controls** — wire the already-generic
   `CardLifecycle.set_channel_controls/2` into the Cards tab. No
   schema change.
4. **Supplementary Card** — add `SUPPLEMENTARY` to the issue-card
   dropdown. No schema change.
5. **Address/Phone/Email/Emboss Name changes** — new
   `cms_{debit,prepaid}_non_monetary_events` table (own FK), mirroring
   `NonMonetaryEvent`'s 4 relevant event types (no `cycle_change` —
   neither product has a billing cycle).
6. **Per-product KYC** — new `kyc_status`/`kyc_verified_at` fields on
   `DebitAccount`/`PrepaidAccount` + a "KYC Verification Workflow"
   toolbar (Verify/Reject/Reset) mirroring Customer's, scoped to that
   product. Confirmed by checking the codebase first: `kyc_status` is
   **purely advisory today, nowhere enforced as a gate** (no product
   creation or card issuance currently checks it) — this stays
   advisory-only for Debit/Prepaid too, consistent with the existing
   convention, not a new business rule invented on top.

### Revised phases

| Phase | Scope |
|---|---|
| **Phase 1e — Debit retrofit** | All 6 items above, applied to Debit — **done 2026-07-28**: account-level Block/Unblock (own `cms_debit_block_history` table), Address/Phone/Email change (`cms_debit_non_monetary_events`), structured POS/ATM velocity limits (JSONB, admin-editable, not yet enforced on the live auth path), per-card channel controls (reused `CardLifecycle.set_channel_controls/2` unchanged), Supplementary card option, per-product KYC (Verify/Reject/Reset, advisory-only). 6 new UI-level tests, 13/13 passing; full suite 366 tests / same 10 pre-existing failures, no regression. Two real bugs fixed live: the `@block_reason_codes`/`@unblock_reason_codes` tuples were built `{code, description}` but the render `{label, val}` destructuring needed `{description, code}` — selects were submitting the description text instead of the code; and module-attribute option lists (`@block_codes` etc.) aren't visible inside a `~H` sigil at all (`@foo` always means `assigns.foo` there) — fixed by lifting them into `mount`'s assigns, the same convention `AccountComponent` already uses. |
| **Phase 2d — Prepaid retrofit** | All 6 items above, applied to Prepaid — **done 2026-07-28**: same shape as Debit's Phase 1e (own `cms_prepaid_block_history`/`cms_prepaid_non_monetary_events` tables, structured POS/ATM velocity limits, per-card channel controls, Supplementary card option, per-product KYC). Applied the two Phase 1e lessons proactively this time (reason-code tuple order, module-attribute-into-assigns) — all 13 new tests passed on the first run, no fix-forward needed. Full suite 377 tests / same 10 pre-existing failures, no regression. |
| **Phase 3 — HCS Employee Cards** | Now includes full parity (all 6 items + the wizard/tabs/Adjustments already planned) from the start, not as a later catch-up |
| **Phase 4 — HCS Corporate polish** | Unchanged — Fleet Cards/Spending Controls/Reports reorganized into tabs |
