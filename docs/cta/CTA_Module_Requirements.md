# CTA — Card Transaction Administration (Card Issuance & Lifecycle): Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus card-production domain knowledge, cross-checked against `lib/vmu_core/cta/`. Validate with SME/product before implementation planning.
**Roadmap linkage:** `VISIONPLUS_ROADMAP.md` Phase 5 (Card Management admin UI).

---

## 1. Purpose & Scope

CTA owns the **physical/virtual card as an artifact**: issuance, embossing, PIN issuance, activation, replacement, renewal, and stock. The account (CMS) is the credit relationship; the card is the access instrument — one account can hold several cards (primary, supplementary, replacement generations, virtual).

**Boundary test:** plastic/credential lifecycle → CTA. Spending capability and balances → CMS. PIN *verification at authorization time* → FAS (HSM); PIN *issuance and change workflows* → CTA.

## 2. Where CTA Sits

| Direction | Module | Contract |
|---|---|---|
| ← CMS | Account | Card is issued against an account + emboss name |
| → FAS | Authorization | Card status (active/blocked) must be visible to auth path (hot card cache) |
| → HSM (FAS-P7) | PIN | PIN blocks generated/verified via `VmuCore.FAS.HSM`; hashes in `cms_card_pins` |
| → Embossing bureau | File | Batch emboss file (fixed format per personalization vendor) |
| → CIF | Identity | Emboss name derives from customer + account preference |
| ← IVR | Activation/PIN | Phone-channel activation and PIN set call CTA services |

## 3. VisionPlus Feature Inventory

### 3.1 Card Issuance (FR-CTA-001 … 012)

| FR | Feature | Notes |
|---|---|---|
| 001 | New card issuance on account creation (auto or manual trigger) | |
| 002 | PAN generation from BIN range + Luhn; PAN tokenization (never store raw) | |
| 003 | Expiry assignment per LOGO validity period | |
| 004 | CVV/iCVV generation via HSM (CVK) | SoftHSM algorithm exists (FAS-P7) |
| 005 | Card types: primary, supplementary, virtual, corporate (HCS) | |
| 006 | Instant/virtual issuance (digital-first, physical follows) | |
| 007 | Emboss file generation: batch, vendor fixed-format, per-run manifest | |
| 008 | PIN mailer generation OR digital PIN-set flow | |
| 009 | Card stock inventory: BIN ranges, plastic stock levels, reorder alerts | |
| 010 | Bulk issuance (corporate programs, migrations) | |
| 011 | Reissue on product upgrade/downgrade (LOGO change) | |
| 012 | Emboss name rules (length, transliteration, title handling) | |

### 3.2 Card Lifecycle (FR-CTA-013 … 025)

| FR | Feature | Notes |
|---|---|---|
| 013 | Card statuses: ORDERED → EMBOSSED → DISPATCHED → INACTIVE → ACTIVE → BLOCKED → EXPIRED / DESTROYED | |
| 014 | Activation: IVR / app / OTP / first-PIN-transaction; activation window enforcement | |
| 015 | Deactivation / temporary block by cardholder | |
| 016 | Replacement: lost/stolen/damaged — new PAN vs same PAN rules | lost/stolen forces new PAN |
| 017 | Renewal: auto-reissue N days before expiry; skip if dormant/blocked | |
| 018 | PIN set / change / unlock (try-counter reset) with authority controls | try counter in `cms_card_pins` |
| 019 | Card destruction / return-to-sender processing | |
| 020 | Replacement fee assessment (waivable) | `card_replacement_fee` logo param exists |
| 021 | Dispatch tracking (courier reference, delivery confirmation) | |
| 022 | Card-level channel controls (ecom/atm/contactless per card) | account-level flags exist; card-level ⬜ |
| 023 | Digital wallet tokenization lifecycle (Apple/Google Pay token provisioning) | |
| 024 | Card event history (issued, activated, blocked, replaced — audit) | |
| 025 | Expiry sweep: mark expired, suppress auth, trigger renewal report | |

## 4. Current Implementation Map (`lib/vmu_core/cta/`)

| File | Covers |
|---|---|
| `card_activation.ex` | Activation workflow |
| `pin_issuance.ex` | PIN issuance/mailer flow |
| `embossing_file_generator.ex` | Vendor emboss batch file |
| `stock_inventory.ex` | BIN range / stock tracking |
| `bureau_adapter.ex` | Personalization bureau interface |
| `cms/card_pin.ex` (CMS) | PIN hash + salt + try counter + lock (FAS-P7) |
| `fas/hot_card_cache.ex` (FAS) | Blocked-card visibility on auth path |

> **Note:** There is no first-class Card schema/table — card state currently lives on `cms_accounts` (pan_token, emboss fields) + `cms_supplementary_cards`. A `cta_cards` entity (one row per plastic generation) is the likely foundation gap for replacement/renewal/history.

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Activation, PIN issuance, emboss file, stock | ✅ Modules exist (depth unverified) |
| First-class card entity with per-plastic lifecycle + history (FR-013/024) | ⬜ Missing — biggest structural gap |
| Replacement / renewal flows (FR-016/017/025) | ⬜ Not found |
| PIN change/unlock ops workflows (FR-018) | 🔄 Storage + verify exist (FAS-P7); ops/set flows + admin UI missing (Roadmap 5.4) |
| Virtual/instant issuance (FR-006), wallet tokens (FR-023) | ⬜ Not found |
| Card-level channel controls (FR-022) | ⬜ Account-level only today |
| Admin UI (Roadmap Phase 5, items 5.1–5.8) | ⬜ Entire phase pending |

## 6. Open Questions

1. Personalization vendor + exact emboss file spec (record layout, delivery channel, encryption).
2. New-PAN-on-replacement policy per reason code (lost/stolen = always new; damaged = same PAN?).
3. Renewal lead time (days before expiry) and dormancy suppression rule.
4. Is digital wallet tokenization (FR-023) v1 scope? Requires scheme token service integration.
5. PIN set channels for v1: IVR only, or app/web with HSM-backed PIN block translation?
