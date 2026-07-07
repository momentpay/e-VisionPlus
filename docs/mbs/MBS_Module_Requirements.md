# MBS — Merchant Business Services: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus MBS domain knowledge, cross-checked against `lib/vmu_core/mbs/`. **Scope decision needed first** (see §6 Q1): MBS is inherently acquirer-side; this platform is issuer-first, and the tmsuat `settlement_core` umbrella already covers acquirer settlement for UAE POS.

---

## 1. Purpose & Scope

In full VisionPlus, MBS is the **acquirer-side merchant module**: merchant onboarding, terminal management, MDR (merchant discount rate) computation, merchant settlement/payout, and merchant statements. For an issuer-first deployment its practical scope narrows to (a) the merchant/terminal reference data the issuer needs (LMS merchant-funded offers, dispute investigation, MCC analytics) and (b) any on-us acquiring the platform performs.

## 2. Where MBS Sits

| Direction | Module | Contract |
|---|---|---|
| ← TRAMS | Transactions | Merchant/terminal reference for clearing + inquiry display (currently inline per ADR-T4) |
| → LMS | Offers | Merchant-funded loyalty offers + merchant settlement of redemptions |
| ← DPS | Investigation | Merchant detail for dispute research |
| ↔ settlement_core (tmsuat) | Acquiring | Existing production acquirer settlement engine — **do not duplicate** |

## 3. VisionPlus Feature Inventory

### 3.1 Merchant Master (FR-MBS-001 … 008)

| FR | Feature | Notes |
|---|---|---|
| 001 | Merchant onboarding: legal entity, DBA, MCC, address, bank account | `merchant.ex` exists |
| 002 | Merchant hierarchy: chain → store → terminal | |
| 003 | Merchant statuses (active/suspended/terminated) + MATCH-list screening | |
| 004 | Terminal (TID) registration + configuration | `terminal.ex` exists |
| 005 | Merchant risk categorization + reserve requirements | |
| 006 | Merchant document/KYB store | |
| 007 | Merchant contact + payout account maintenance | |
| 008 | MCC reference data with category groupings | |

### 3.2 Pricing & Settlement (FR-MBS-009 … 016) — *acquirer-side*

| FR | Feature | Notes |
|---|---|---|
| 009 | MDR schemes: flat %, tiered, interchange-plus per MCC/product | `mdr_engine.ex` exists |
| 010 | Merchant settlement cycle (T+1/T+2) + payout files | settlement_core owns today |
| 011 | Merchant statements (gross, MDR, net, chargebacks) | |
| 012 | Chargeback debit to merchant + reserve draw | |
| 013 | Interchange + scheme fee pass-through accounting | settlement_core has rate tables |
| 014 | Merchant fee invoicing (rental, minimums) | |
| 015 | Tax handling on MDR (VAT/GST) | |
| 016 | Merchant payout reconciliation | |

## 4. Current Implementation Map (`lib/vmu_core/mbs/`)

| File | Covers |
|---|---|
| `merchant.ex` | Merchant master schema |
| `terminal.ex` | Terminal registration |
| `mdr_engine.ex` | MDR computation |
| `settlement_core` (tmsuat umbrella) | Production acquirer settlement, interchange/MDR rate tables, payout — the heavyweight overlap |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Merchant/terminal/MDR basics | ✅ Schemas + engine exist (depth unverified) |
| Merchant hierarchy, risk/reserves, KYB, MATCH screening | ⬜ Not found |
| Settlement/payout/statements (FR-010–016) | ⚠️ **Overlap** — settlement_core already does this for acquiring; building in vmu_core would duplicate |
| Issuer-need: merchant master feeding TRAM inquiry + LMS offers | ⬜ TRAM stores merchant inline (ADR-T4) pending this master |
| Ops UI | ⬜ None |

## 6. Open Questions (blocking — answer before any MBS build)

1. **Scope decision:** Is vmu_core MBS (a) issuer-side merchant *reference* master only, (b) full acquiring including settlement (conflicts with settlement_core), or (c) thin wrapper exposing settlement_core data in the vmu_core admin? Recommendation: (a) + (c).
2. If (a): the TRAM ADR-T4 deferral resolves here — migrate inline merchant fields to the master once populated. Data source for the master?
3. LMS merchant settlement (`lms/merchant_settlement*.ex`) already exists — should MBS own merchant payout for loyalty redemptions, or stay in LMS?
