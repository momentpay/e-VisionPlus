# Way4 Parity Plan — Phase 1: Card Portfolio Expansion — Tracker

> Companion to [`Way4_Parity_Implementation_Plan.md`](Way4_Parity_Implementation_Plan.md)
> §2 "Phase 1 — Card portfolio expansion". Namespaced separately from
> `docs/phase1-implementation-spec.md` (the *original* Phase 1 of the
> unrelated 8-phase build tracker in `docs/phase-tracker.md`) — same
> "don't collide with the other Phase 1-8" discipline `docs/fas/
> FAS_Implementation_Tracker.md` already established for FAS-P1..P8.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `🔴 Blocked`

Detailed per-file build logs live in each owning module's own tracker
(`docs/cta/CTA_Gap_Implementation_Tracker.md`, a new `docs/hcs/
HCS_Gap_Implementation_Tracker.md`, etc.) — this doc is the cross-cutting
status/sequencing overview for the whole phase, matching how the parent
Way4 plan points at each module's own tracker for Phase 0.

---

## Sequencing decision (2026-07-25)

Before starting, checked whether any of the 7 items already had real work
sitting lost in `Avenza` — the same discovery that found COL/LMS/ASM-SSO
lost the same way in Phase 0 (7 confirmed instances by the end of that
phase). Findings changed the sequencing:

| Item | Real Avenza work? | Verdict |
|---|---|---|
| Virtual Cards | ✅ Yes — complete, self-contained vertical slice (PAN gen, credential vault, issue+reveal API), no `wallet_*` dependency | **Port** |
| Corporate Cards | ✅ Yes — facility-limit maker-checker + daily-cap/cash-access controls, additive to vmu_core's already-solid HCS baseline | **Port** |
| Fleet Cards | ✅ Yes — complete v1 slice (vehicle/driver/fleet-card/onboarding/report), vmu_core already has the migration | **Port** |
| Debit | ⚠️ Yes, but dead/stubbed — Avenza's own code comments (2026-07-22) call it unexercised, self-flagged as superseded, with known unfixed bugs | **Build native, don't port** |
| Prepaid | ⚠️ Yes, but depends on the `wallet_*` apps (`WalletLedger`, `wallet_accounts`) that don't exist in standalone vmu_core — contradicts this very phase's own "native FAS→TRAMS→GL, no product bypasses this pipeline" principle | **Build native, don't port** |
| BNPL (merchant) | ❌ No — genuine gap in both repos | Blocked on `MerchantManagementSystem` integration contract |
| Tokenization/Apple/Google Pay | ❌ No — genuine gap in both repos | Blocked on vendor decision (Way4 plan §3 Decision 1) |

**Confirmed sequencing with user**: Virtual Cards → Corporate Cards →
Fleet Cards → Debit (native) → Prepaid (native) → BNPL/Tokenization last
(both externally blocked, not started until their respective decisions
land).

---

## 1. Virtual Cards — finish the issuance flow

**Status: ✅ Done (2026-07-25)**

Port from Avenza (`apps/vmu_cta`), re-verified against vmu_core's own
current schema/conventions before trusting any of it, same discipline as
every prior re-port this session.

**Scope correction found before building the API layer**: Avenza's
`VirtualCardController`/`/api/v1` existed specifically for `wallet-app`
to call remotely (service-account bearer auth) — that layer doesn't
exist in vmu_core at all, and there's no external caller for it here.
Confirmed with user: expose issuance/reveal through the admin console
instead (`AccountComponent`'s existing Cards tab, which already hosts
every other card-lifecycle action), not a new REST API with no consumer.

| # | Task | Avenza source | Status |
|---|---|---|---|
| V1.1 | `CTA.PanGenerator` — BIN + random digits + Luhn check digit, SHA-256 pan_token | `vmu_cta/lib/vmu_core/cta/pan_generator.ex` | ✅ |
| V1.2 | `CardLifecycle.issue_new/2` — general new-card issuance (PRIMARY/SUPPLEMENTARY/VIRTUAL) | `vmu_cta/lib/vmu_core/cta/card_lifecycle.ex` | ✅ |
| V1.3 | `CTA.CredentialVault` — ETS-backed, exactly-once reveal, TTL sweep; registered in `VmuCore.Application`'s supervision tree | `vmu_cta/lib/vmu_core/cta/credential_vault.ex` | ✅ |
| V1.4 | `CardLifecycle.issue_virtual_with_credentials/2` — issue + auto-activate + CVV + vault stash | `vmu_cta/lib/vmu_core/cta/card_lifecycle.ex` | ✅ |
| V1.4a | `HSM.generate_cvv/3` (`CW` command) — did **not** exist in vmu_core's `VmuCore.FAS.HSM` behaviour at all (only `verify_cvv/4`); added to the behaviour + `SoftHSM` (reuses the existing private `compute_cvv/4`) + `ProductionHSM` (real `CW` REST call, built from the manual, mirrors `CY`'s shape) + `SocketHSM` stub | new, not in Avenza's scope either | ✅ |
| V1.5 | Admin UI — "Issue New Card" action + exactly-once "Reveal" button on VIRTUAL cards, added to the existing `AccountComponent` Cards tab (not a new component) | new (replaces Avenza's `VirtualCardController`) | ✅ |
| V1.6 | Real tests | new | ✅ 21/21 (5 `pan_generator_test.exs`, 3 `credential_vault_test.exs`, 8 `card_lifecycle_issue_test.exs`, 2 `account_component_card_issue_test.exs`, + coverage from fixing the bug below) |

**Real pre-existing bug found and fixed**: `AccountComponent`'s
top-level `<%= if @active_action != :none do %>` block rendered
`render_action_panel/1` for **every** action, including all `card_*`
ones — which `tab_cards/1` **also** renders in its own gated block. Every
existing card action (`card_activate`/`card_block`/`card_unblock`/
`card_replace`/`card_renew`/`card_channels`) has been double-rendering
its panel since this file was written; never caught because it had zero
tests before this item's own test suite (the first for this 2900+-line
component) hit it via the new `:card_issue` action. Fixed by excluding
card-level actions from the top-level condition — they render once,
correctly, inside the Cards tab.

Full CTA/CMS/FAS/ASM/COL/admin regression before and after: same 10
pre-existing, already-documented failures, zero regressions.

---

## 2. Corporate Cards

**Status: ⬜ Pending — not started**

vmu_core's baseline (`HCS.Company`, `EmployeeCard`, `SpendingControl`,
`LimitController`, `ConsolidatedStatementGenerator`, `PaymentSweep`,
`CompanyOnboarding`) already matches Avenza closely — this phase ports
the **additive** pieces only.

| # | Task | Avenza source | Status |
|---|---|---|---|
| C1.1 | `HCS.FacilityLimitChange` schema (PENDING_APPROVAL/APPROVED/REJECTED) | `vmu_hcs/lib/vmu_core/hcs/facility_limit_change.ex` | ⬜ |
| C1.2 | `HCS.FacilityLimitCommand` — `request/3`/`approve/2`/`reject/2`/`pending/1`, maker≠checker via `ModuleConfigEngine`, mirrors `COL.WorkoutCommand`'s pattern | `vmu_hcs/lib/vmu_core/hcs/facility_limit_command.ex` | ⬜ |
| C1.3 | `LimitController`/`SpendingControl` — DAILY_CAP control type + per-transaction `daily_spend` tracking, cash-access check | diff vs. vmu_core's current `limit_controller.ex`/`spending_control.ex` (~235 diff-lines) | ⬜ |
| C1.4 | Admin UI wiring for the approval workflow (confirm whether Avenza built one or if this needs a new LiveComponent, matching COL/CMS's admin-screen pattern) | TBD — check at implementation time | ⬜ |
| C1.5 | Real tests | new | ⬜ |

---

## 3. Fleet Cards

**Status: ⬜ Pending — not started**

vmu_core has the migration (`20260712000006_create_hcs_fleet_tables.exs`
— `hcs_vehicles`, `hcs_driver_assignments`, `hcs_fleet_cards`, plus an
alter on `hcs_spending_controls`) but zero Elixir code against it.
**Verify the migration's column set still matches Avenza's schemas
exactly before wiring anything in** — Avenza's own repo has no migration
for these tables at all (relies on a shared dev DB already having them),
so this is unverified until checked directly.

| # | Task | Avenza source | Status |
|---|---|---|---|
| F1.1 | Confirm `hcs_vehicles`/`hcs_driver_assignments`/`hcs_fleet_cards` migration columns match Avenza's schema field-for-field | n/a — direct comparison | ⬜ |
| F1.2 | `HCS.Vehicle`, `HCS.FleetCard` schemas | `vmu_hcs/lib/vmu_core/hcs/vehicle.ex`, `fleet_card.ex` | ⬜ |
| F1.3 | `HCS.DriverAssignment` + `HCS.DriverAssignmentCommand` — current/history tracking, transactional close-then-open | `vmu_hcs/lib/vmu_core/hcs/driver_assignment.ex`, `driver_assignment_command.ex` | ⬜ |
| F1.4 | `HCS.FleetOnboarding` — `add_vehicle/2`, `add_fleet_card/3` (validates against shared company credit pool across employee+fleet allocations, creates synthetic `CMS.Account` per vehicle) | `vmu_hcs/lib/vmu_core/hcs/fleet_onboarding.ex` | ⬜ |
| F1.5 | `HCS.FleetReport` — spend-by-driver, off the same ledger `ConsolidatedStatementGenerator` uses. v1 scope explicitly: no fuel-line-item detail, doesn't split spend across mid-period driver reassignment (carry the same explicit flag forward, don't silently drop it) | `vmu_hcs/lib/vmu_core/hcs/fleet_report.ex` | ⬜ |
| F1.6 | `LimitController` generalization to enforce `FleetCard` alongside `EmployeeCard` (shares C1.3's diff) | — | ⬜ |
| F1.7 | Real tests | new | ⬜ |

---

## 4. Debit Card Issuing (native build, not ported)

**Status: ⬜ Pending — not started, design not yet written**

Avenza's `WalletDebitAdapter`/`run_debit_authorization/1` is explicitly
not being ported (self-flagged dead code with known bugs in its own
comments). Per the parent Way4 plan's own framing: new `account_class:
DEBIT` on `cms_accounts` (balance-funded, no OTB/credit_limit), FAS
available-funds check reused with a debit-specific "available"
computation, same SYS→BANK→LOGO→BLOCK/FAS/TRAMS pipeline every other
product in this repo uses — no wallet dependency.

Needs its own design pass before implementation starts (matching the
"write the module's own Requirements.md gap analysis before code"
discipline used everywhere else in this repo) — `docs/debit/
DEBIT_Module_Requirements.md` already exists as a planning stub; review
it for currency before treating it as ready-to-build-against.

---

## 5. Prepaid Cards (native build, not ported)

**Status: ⬜ Pending — not started, design not yet written**

Avenza's prepaid auth path is real and live but resolves through
`WalletLedger.Commands.AuthorizeCardDebit` — a `wallet_*`-app dependency
that doesn't exist here. Building this natively means the actual
"prepaid program" layer (funding, load, dormancy, reconciliation —
currently living in `wallet_accounts`/`wallet_web` in Avenza, not
portable 1:1) needs an in-house equivalent inside vmu_core's own
CMS/CTA, closed-loop clearing through TRAMS (issuer is also acquirer for
on-us transactions), consistent with this repo's "no product bypasses
FAS→TRAMS→GL" principle.

Needs its own design pass before implementation starts — check `docs/
prepaid/` for an existing requirements stub first.

---

## 6. BNPL (merchant) — blocked

**Status: 🔴 Blocked — no work until the integration contract exists**

Confirmed genuinely unbuilt in both repos (checked `vmu_mbs`,
`wallet_loans`, `wallet_transfers` — nothing merchant-checkout-BNPL
shaped anywhere). Real dependency is an integration contract with
`MerchantManagementSystem` (merchant eligibility/participation data),
not anything inside this repo — scoping that integration is the actual
first step, not vmu_core code.

## 7. Tokenization / Apple Pay / Google Pay — blocked

**Status: 🔴 Blocked — no work until a vendor is chosen**

Confirmed genuinely unbuilt in both repos. Blocked on Way4 parity plan
§3 Decision 1 (Visa Token Service vs. Mastercard MDES, and whether
Apple/Google Pay are in scope for this phase or a later one).
