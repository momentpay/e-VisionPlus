# IVR — Integrated Voice Response (Telephony Channel): Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus telephony-channel domain knowledge, cross-checked against `lib/vmu_core/ivr/`. See `../its/ITS_Module_Requirements.md` §1 for the ITS/IVR naming clarification.

---

## 1. Purpose & Scope

IVR is the **phone self-service channel**: automated cardholder identification and a menu of self-service functions (balance, activation, PIN, block card) plus warm handoff to a CS agent with screen-pop context. Architecturally it is a *channel adapter* — business logic stays in CMS/CTA/FAS; IVR orchestrates sessions and delegates.

## 2. Where IVR Sits

| Direction | Module | Contract |
|---|---|---|
| ↔ Telephony platform | Sessions | SIP/CTI vendor integration drives the session GenServers |
| → CIF/CMS | Identification | Caller verification (card last-4 + DOB/ID + OTP) |
| → CMS | Inquiry | Balance, due date, min payment, recent transactions (via TRAM read) |
| → CTA | Actions | Card activation, PIN set/change, card block |
| → FAS/HotCardCache | Block | Lost/stolen report → immediate hot-card block |
| → CS desktop | Handoff | Screen-pop context (verified customer + intent) |

## 3. VisionPlus Feature Inventory

### 3.1 Session & Identification (FR-IVR-001 … 007)

| FR | Feature | Notes |
|---|---|---|
| 001 | Session lifecycle per call (state machine, timeout, resume) | `ivr_session.ex` + `IVR.SessionRegistry` in supervision tree |
| 002 | Caller identification: PAN last-4 / account no. + knowledge factors | |
| 003 | OTP verification to registered mobile | `otp_engine.ex` |
| 004 | Failed-verification lockout + fallback to agent | |
| 005 | Language selection | |
| 006 | DTMF + (optionally) speech input handling | vendor-side mostly |
| 007 | Session audit trail (menu path, outcomes) | |

### 3.2 Self-Service Functions (FR-IVR-008 … 016)

| FR | Feature | Notes |
|---|---|---|
| 008 | Balance / available credit / due date / min payment inquiry | |
| 009 | Recent transactions readout (last N) | via TRAM search |
| 010 | Card activation | → CTA `card_activation` |
| 011 | PIN set / change via secure DTMF | → HSM PIN flows (FAS-P7) |
| 012 | Lost/stolen report → immediate block + replacement order | → hot card cache + CTA |
| 013 | Statement copy request | → ITS copy / CMS fee |
| 014 | Payment by phone (gateway integration) | |
| 015 | Dispute initiation handoff (capture intent, route to DPS intake) | |
| 016 | Agent transfer with context (screen-pop payload) | |

## 4. Current Implementation Map (`lib/vmu_core/ivr/`)

| File | Covers |
|---|---|
| `ivr_session.ex` | Session GenServer (registered in `VmuCore.IVR.SessionRegistry` — supervision tree slot 5) |
| `otp_engine.ex` | OTP generation/verification |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Session GenServer + OTP | ✅ Exist (depth unverified) |
| Telephony platform integration (FR-001 transport, FR-006) | ⬜ No vendor adapter found — sessions are driven by what? verify |
| Self-service function wiring (FR-008–013) | ⬜ verify which are implemented inside session flows |
| Payment by phone (FR-014) | ⬜ Not found |
| Screen-pop handoff (FR-016) | ⬜ Not found |
| Session audit (FR-007) | ⬜ verify |

## 6. Open Questions

1. Telephony vendor/platform (Asterisk? Genesys? cloud CPaaS?) — the integration adapter is the real build here.
2. Which self-service functions for v1 (activation + balance + lost/stolen is the usual minimum).
3. PIN-by-phone security posture: DTMF PIN entry requires PCI-compliant capture at the telephony edge — confirm approach before FR-011.
