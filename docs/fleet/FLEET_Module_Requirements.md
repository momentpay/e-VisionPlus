# Fleet Cards — Product Feasibility & Requirements

**Status:** 📝 New-product planning doc (2026-07-11) — not started.
`LogoParameter.product_type` accepts `"FLEET"` as a stored value, but — like
`"DEBIT"`/`"PREPAID"` — it's pure reference metadata never read by any
business logic.

---

## 1. Purpose & Scope

A fleet card is a **commercial credit product** restricted to fuel and
vehicle-related spend (fuel stations, maintenance/repair, sometimes tolls),
typically issued per-vehicle or per-driver under a single company facility,
with purchase data captured at a level of detail beyond a normal
transaction (fuel type, gallons/litres, price per unit, odometer reading)
for expense control and fraud detection (e.g. flagging a fill-up bigger than
the vehicle's tank, or two fill-ups for one vehicle an hour apart in
different cities).

**This is the least architecturally distant of the six products in this
batch.** Unlike Debit/Prepaid/WPS, a fleet card **is a credit product** — it
has a company facility, per-card sub-limits, and revolving (or fully-paid
monthly) billing, which is exactly the shape HCS already implements for
corporate cards. The real gap is narrower: MCC restriction to fuel/auto
merchants (mostly already possible), vehicle-level sub-accounts (not
employee-level), and enhanced line-item data capture (genuinely new).

## 2. Where This Sits — and What HCS Already Gives For Free

The 2026-07-11 HCS module review (see `../hcs/HCS_Module_Requirements.md`)
found real, live-verified infrastructure that maps directly onto most of
what a fleet card needs:

| Fleet requirement | HCS equivalent, confirmed real and wired |
|---|---|
| Company facility with per-vehicle sub-limits | `Company` (facility limit) + `EmployeeCard` (per-card `individual_limit`) — rename the concept from "employee" to "vehicle/driver," same shape |
| MCC restriction to fuel merchants | `SpendingControl` with `control_type: "MCC_ALLOW"` — **already enforced on the real hot path** (`LimitController.apply_control/4`, called from `AccountStateCoordinator.do_authorize/4`) |
| Per-transaction / daily caps | `TXN_CAP` is enforced; **`DAILY_CAP` is not** — flagged as a real gap during the HCS review (schema-valid, documented in the UI mockup, but `apply_control/4` has no clause for it). Fleet cards commonly rely on daily fuel caps, so this pre-existing gap becomes directly relevant here and should be fixed as part of this work, not treated as a separate HCS-only concern. |
| Central company billing | `PaymentSweep`/`ConsolidatedStatement` — real aggregation logic already exists |
| Cash-access control | `EmployeeCard.can_withdraw_cash` — **field exists but is never read anywhere** (also flagged during the HCS review). Fleet cards should always block cash withdrawal; this needs the same enforcement gap closed. |

**⚠ Cross-repo check, 2026-07-11:** confirmed the sibling `wallet-app` repo
has no equivalent concept at all — no company/facility/commercial-limit
entity anywhere in its domain map, and its 7 auth roles include only a
`customer`/`customer_business` flag, not a facility-and-sub-limit structure.
Fleet is fundamentally a commercial *credit* product, and vmu_core/HCS is the
only one of the two codebases with that model built and wired. **This one
belongs in vmu_core, not wallet-app** — unlike Prepaid/Debit/WPS/BNPL, which
lean the other way (see their respective docs).

**What HCS genuinely does not give**: vehicle identity (VIN, plate,
odometer) as a first-class concept — `EmployeeCard` models a person, not a
vehicle — and enhanced fuel line-item data, which requires parsing
additional ISO 8583 data fields fuel dispensers send (product type,
unit price, quantity, odometer) that FAS's current message handling doesn't
extract today.

## 3. Net-New Build Required

| Area | What's needed |
|---|---|
| Vehicle/driver sub-account | A `FleetCard` (or extend `EmployeeCard`'s shape) keyed by vehicle (VIN/plate) or driver instead of employee identity |
| DAILY_CAP enforcement | Close the pre-existing HCS gap — needed for fleet's typical daily-fuel-limit control, not fleet-specific work in itself |
| Cash-access enforcement | Wire `can_withdraw_cash` (or its fleet equivalent) into the actual authorization check — currently a dead field |
| Enhanced line-item capture | Parse fuel-specific ISO 8583 data (product type, unit price, quantity, odometer) from the authorization/clearing message — needs the real fuel-dispenser data spec (same "don't guess a spec" caution as this session's Mastercom/WPS work) |
| Odometer/mileage tracking | Capture + a basic MPG/consumption anomaly check for fraud detection |
| Fleet-specific reporting | Fuel spend by vehicle/driver/fuel-type, consumption anomalies |

## 4. Feature Inventory (draft — validate with product before build)

| FR | Feature |
|---|---|
| 001 | Company fleet facility (reuses `HCS.Company`) |
| 002 | Per-vehicle/per-driver card issuance under the facility |
| 003 | MCC restriction to fuel/auto-maintenance merchants (reuses `MCC_ALLOW`, already real) |
| 004 | Daily and per-transaction fuel-spend caps (`TXN_CAP` real; `DAILY_CAP` needs the enforcement fix noted above) |
| 005 | Cash-access always blocked (needs the enforcement fix noted above) |
| 006 | Odometer capture at point of sale |
| 007 | Fuel line-item detail: product type, unit price, quantity |
| 008 | Consumption/MPG anomaly flagging for fraud detection |
| 009 | Central company billing (reuses `PaymentSweep`/`ConsolidatedStatement`) |
| 010 | Fleet reporting: spend by vehicle/driver/fuel-type, exceptions |

## 5. Phased Implementation Plan (high-level — refine before starting)

1. **Phase F1 — Close the two pre-existing HCS enforcement gaps.**
   `DAILY_CAP` and `can_withdraw_cash` — these are needed for fleet
   regardless, and fixing them benefits HCS's existing corporate-card
   product too. Smallest, highest-leverage first step.
2. **Phase F2 — Vehicle/driver sub-account.** Decide: extend `EmployeeCard`
   with vehicle fields, or a parallel `FleetCard` schema reusing the same
   `Company`/`LimitController` plumbing. Recommend a parallel schema —
   "employee" and "vehicle" are different identity concepts even if the
   limit/control mechanics are identical, and conflating them risks the
   same kind of schema-overload issues seen elsewhere in this project.
3. **Phase F3 — Card issuance wiring.** Point CTA's card entity at fleet
   sub-accounts — should be close to free, same reasoning as Debit/Prepaid.
4. **Phase F4 — Enhanced line-item capture.** Get the real fuel-dispenser
   data spec before building; parse into a new fuel-transaction-detail
   record linked to the clearing/authorization record.
5. **Phase F5 — Anomaly detection + reporting.**
6. **Phase F6 — Ops UI** (vehicle roster, fuel reports) — likely an
   extension of the HCS admin UI once it exists, per HCS's own still-open
   "no ops UI" gap.

## 6. Open Questions (need product/business input before F1 starts)

1. Vehicle identity: VIN, plate number, or both? Does the system need to
   track vehicle ownership/assignment history (driver reassigned to a
   different vehicle over time)?
2. Is enhanced fuel line-item data (odometer, product type, unit price) a
   v1 requirement, or can v1 ship as "HCS corporate card with fuel MCC
   restriction" and add line-item detail later? This materially changes
   scope — the MCC-restricted-corporate-card version is buildable almost
   entirely from existing HCS infrastructure plus the two enforcement
   fixes; line-item capture is the genuinely new part.
3. Toll/parking spend in scope alongside fuel, or fuel-only for v1?
4. Which acquirer/network fuel-dispenser data format applies in the target
   market(s) — needed before Phase F4 can start for real.
