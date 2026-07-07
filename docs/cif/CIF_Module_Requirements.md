# CIF — Customer Information File: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus CIF domain knowledge, cross-checked against `lib/vmu_core/shared/customer.ex` and the Phase 3 admin UI. Validate with SME/product before implementation planning.

---

## 1. Purpose & Scope

CIF is the **customer master above the account layer**: one customer, many accounts (and via HCS, many corporate relationships). It owns identity, KYC, contactability, and the customer-level view of exposure and relationships. In VisionPlus the hierarchy is:

```
Customer (CIF)  →  Account (CMS)  →  Card (CTA)  →  Transaction (TRAMS/FAS)
```

**Boundary test:** anything true of the *person/company regardless of which account* belongs in CIF; anything account-specific belongs in CMS.

## 2. Where CIF Sits

| Direction | Module | Contract |
|---|---|---|
| → CMS | Account creation | Account must reference an existing (KYC-cleared) customer |
| → CDM | Origination | Application scoring reads customer identity + bureau keys |
| → HCS | Corporate | Company ↔ employee-cardholder relationships |
| ← ASM | Operator access | Customer-data visibility is role-gated (PII) |
| → Notifications | Contactability | Address/phone/email are the source of truth for statements/alerts |

## 3. VisionPlus Feature Inventory

### 3.1 Customer Master (FR-CIF-001 … 012)

| FR | Feature | Notes |
|---|---|---|
| 001 | Customer record: individual vs business/corporate tier | |
| 002 | Personal data: name(s), DOB, gender, nationality, language | |
| 003 | Identity documents: type, number, issuer, expiry (multiple per customer) | |
| 004 | Contact: mobile, phone, email with verified flags | |
| 005 | Addresses: residential, mailing, office — typed, multiple, with effective dates | |
| 006 | Employment / income data (drives CDM affordability) | |
| 007 | Corporate fields: legal name, registration no., incorporation, industry | |
| 008 | Customer status: ACTIVE / INACTIVE / DECEASED / BLACKLISTED | |
| 009 | Customer memo/notes with operator attribution | |
| 010 | Preferred channel + paperless election | |
| 011 | FATCA/CRS tax residency data | |
| 012 | Customer merge (duplicate consolidation) with account re-parenting | |

### 3.2 KYC & Compliance (FR-CIF-013 … 020)

| FR | Feature | Notes |
|---|---|---|
| 013 | KYC status workflow: PENDING → VERIFIED / REJECTED (+ reset) | Admin UI Phase 3 |
| 014 | KYC document capture + expiry-driven re-KYC | |
| 015 | Risk rating (low/medium/high) + enhanced due diligence flag | |
| 016 | Sanctions/PEP screening at onboarding + periodic re-screen | mw_risk `SanctionsChecker` exists but not wired to CIF |
| 017 | Deduplication at creation (ID number, mobile, fuzzy name+DOB) | |
| 018 | Consent management (marketing, data sharing) with timestamps | |
| 019 | Right-to-erasure / data-retention handling (post account closure) | |
| 020 | Audit of every PII view/change (who saw what, when) | ties to ASM |

### 3.3 Relationships & Exposure (FR-CIF-021 … 027)

| FR | Feature | Notes |
|---|---|---|
| 021 | Customer → accounts linkage (list, primary/supplementary roles) | `Customer.list_accounts_for/1` exists |
| 022 | Customer-level total exposure (sum of limits/outstanding across accounts) | feeds CDM limit allocation |
| 023 | Household/guardian relationships (supplementary card holders under 18 etc.) | |
| 024 | Corporate hierarchy: company ↔ employees (delegated to HCS, referenced here) | |
| 025 | Customer-level blocks (blacklist propagates to all accounts) | |
| 026 | Bureau identifiers (bureau subject keys per bureau) | |
| 027 | Relationship manager / branch attribution | |

## 4. Current Implementation Map

| File | Covers |
|---|---|
| `shared/customer.ex` | Customer schema: personal, contact, address, identity, KYC status, tier, corporate fields (Phase 3 / migration `20260616000013`) |
| `vmu_core_web/live/admin/customer_component.ex` | Full CRUD admin UI: search, KYC workflow, corporate tier, linked accounts (Phase 3 ✅) |
| — | No dedicated `cif/` directory — customer lives in `shared/` |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Core master + KYC status workflow + admin UI | ✅ Built (Phase 3) |
| Multiple addresses / identity documents (typed, dated collections) | ⬜ Single embedded fields today, not collections |
| Sanctions/PEP screening wired to onboarding (FR-016) | ⬜ Engine exists in mw_risk; no CIF hook |
| Dedup at creation (FR-017) | ⬜ Not found |
| Customer merge (FR-012) | ⬜ Not found |
| Customer-level exposure roll-up (FR-022) | ⬜ Not found (also flagged in CMS FR-030) |
| Customer-level blacklist propagation (FR-025) | ⬜ Not found |
| Consent, FATCA/CRS, retention (FR-011/018/019) | ⬜ Not found |
| PII access audit (FR-020) | ⬜ Operator audit exists for changes; view-audit not found |

## 6. Open Questions

1. Should CIF get its own `lib/vmu_core/cif/` context (extracting from `shared/`), or stay in shared? (Module boundary consistency vs churn.)
2. Which bureaus/screening providers per market, and is screening blocking or advisory at onboarding?
3. Regulatory retention periods per data class (PII vs financial history).
4. Is customer merge in scope for v1, or is dedup-at-creation sufficient?
