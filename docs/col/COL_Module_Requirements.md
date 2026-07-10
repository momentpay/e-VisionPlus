# COL — Collections & Recovery: Module Requirements

**Status:** 📝 Draft for review — drafted from VisionPlus collections domain knowledge, cross-checked against `lib/vmu_core/col/`. Validate strategies/bucket policy with SME/business before implementation planning.

---

## 1. Purpose & Scope

COL manages **delinquent accounts from first missed payment through recovery or write-off**: queueing by days-past-due (DPD), collector workflows, promises to pay, hardship/workout plans, agency placement, write-off, and post-write-off recoveries. CMS owns the delinquency *state* (bucket aging in EOD); COL owns the *treatment*.

## 2. Where COL Sits

| Direction | Module | Contract |
|---|---|---|
| ← CMS | Delinquency | EOD bucket roll creates/updates collection cases by DPD |
| ← DPS | Exclusion | Open-dispute transactions excluded from collection pressure |
| → CMS | Financial | Write-off posting, recovery posting, payment-plan restructure |
| → Letters/Comms | Dunning | Letter/SMS/email triggers per strategy step |
| → CDM | Feedback | Collection outcome feeds behavioral scoring |
| → Bureau | Reporting | Charged-off status in Metro2 |

## 3. VisionPlus Feature Inventory

### 3.1 Case Management (FR-COL-001 … 010)

| FR | Feature | Notes |
|---|---|---|
| 001 | Auto case creation on delinquency (DPD threshold per product) | |
| 002 | DPD buckets: 1–29, 30, 60, 90, 120, 150, 180+ with bucket-roll history | schema has 30/60/90/120 |
| 003 | Queue segmentation: bucket × balance band × risk score × product | |
| 004 | Collector assignment (individual + team + capacity rules) | |
| 005 | Case notes, contact history (call outcomes, right-party-contact) | |
| 006 | Promise to pay: amount + date, kept/broken tracking, auto-verification against payments | schema has promise fields |
| 007 | Next-action scheduling + follow-up work queues | |
| 008 | Case statuses: OPEN / PROMISED / WORKOUT / AGENCY / WRITTEN_OFF / RECOVERED / CLOSED | implemented |
| 009 | Cure detection: payment clears past-due → case auto-close + bucket reset | |
| 010 | Legal-track flag + litigation hold | |

### 3.2 Strategies & Dunning (FR-COL-011 … 017)

| FR | Feature | Notes |
|---|---|---|
| 011 | Strategy engine: per bucket/segment → ordered treatment steps (SMS day 3, call day 7, letter day 15 …) | |
| 012 | Dunning letter generation per bucket with templates | `dunning_job.ex` exists |
| 013 | Contact-frequency caps (regulatory harassment limits) | |
| 014 | Hardship/workout plans: restructure, reduced APR, payment holiday — with approval levels | |
| 015 | Settlement offers (lump-sum discount) with authority matrix | |
| 016 | Self-cure carve-out (low-risk early bucket gets no outreach for N days) | |
| 017 | Block-code application per bucket (C-block at 30 DPD etc.) | |

### 3.3 Agency, Write-off & Recovery (FR-COL-018 … 025)

| FR | Feature | Notes |
|---|---|---|
| 018 | Agency placement: assignment file out, activity/payment file in, commission accounting | |
| 019 | Agency recall + churn between agencies | |
| 020 | Write-off at policy DPD (typically 180) with approval + GL posting | `write_off_processor.ex` exists |
| 021 | Post-write-off recovery ledger (payments against charged-off principal) | |
| 022 | Recovery agency / debt-sale processing | |
| 023 | Interest/fee suppression post charge-off | |
| 024 | Deceased/bankruptcy special handling (proof-of-claim, stop-collection) | |
| 025 | Collections MI: roll rates, cure rates, promise-kept %, recovery % | Roadmap Phase 8 |

## 4. Current Implementation Map (`lib/vmu_core/col/`)

| File | Covers |
|---|---|
| `collection_case.ex` | Case schema (`col_collection_cases`): bucket, outstanding, status, assignment, promise, write-off fields |
| `collection_queue_job.ex` | Queue/bucket processing job |
| `dunning_job.ex` | Dunning letter trigger job |
| `write_off_processor.ex` | Write-off processing |

## 5. Gap Analysis (initial — verify during planning)

| Area | Assessment |
|---|---|
| Case schema, queue job, dunning job, write-off | ✅ Exist (depth/strategy unverified) |
| Strategy engine (FR-011) — treatments are likely hardcoded in jobs | 🔄 verify |
| Contact history / call outcomes (FR-005) | ⬜ Not found |
| Promise auto-verification against payments (FR-006b) | ⬜ verify |
| Hardship/workout plans (FR-014), settlement offers (FR-015) | ⬜ `workout_plan_id` field exists; no plan module |
| Agency placement files (FR-018/019) | ⬜ `assigned_to` field only |
| Post-write-off recovery accounting (FR-021–023) | ⬜ Not found |
| Dispute exclusion (DPS link) | ⬜ Not found — should check open disputes before escalation |
| Ops UI (Roadmap 6.13–6.16) | ⬜ Pending |

## 6. Open Questions

Here’s a review of your answers with refinements and the missing piece filled in:

---

### 1. **Bucket/Strategy Policy Matrix per Product**
✅ **Your answer is on the right track.**  
- \It should be configurable at both **system‑wide** and **product‑specific** levels.  
- Suggestion: Add that the matrix should support **hierarchical overrides** (global → product → customer segment) and be version‑controlled for audit.  
- Example config:
  ```yaml
  bucket_strategy_matrix:
    default: [bucket1, bucket2, bucket3]
    product_A: [bucketX, bucketY, bucketZ]
  ```

---

### 2. **Agency File Formats & Commission Terms** 
- File formats: Yes, configurable (CSV, XML, JSON, etc.) per agency.  
- Commission terms: Should also be parameterized (flat %, tiered %, fixed fee) and linked to agency ID.  
- Suggestion: Add **validation layer** to ensure agency files match schema before ingestion.  
- Example config:
  ```yaml
  agency_config:
    agency1:
      file_format: "CSV"
      commission: "2%"
    agency2:
      file_format: "XML"
      commission: "tiered: [1%, 2%, 3%]"
  ```

---

### 3. **Write‑off DPD + Approval Matrix; Regulatory 
- Configurable parameters:  
  - `writeoff_dpd_threshold` (e.g., 180 days past due).  
  - `approval_matrix` (roles/levels required for write‑off).  
  - `ifrs9_stage_mapping` (Stage 1, 2, 3 provisioning rules).  
- Example config:
  ```yaml
  writeoff_policy:
    IN:
      dpd_threshold: 180
      approval_matrix: ["branch_manager", "risk_head"]
      ifrs9_stage: "Stage3"
    EU:
      dpd_threshold: 360
      approval_matrix: ["risk_committee"]
      ifrs9_stage: "Stage2"
  ```
- Benefit: Aligns provisioning with regulatory expectations and ensures auditability.

---

### 4. **Regulatory Contact Caps in Target Markets**
✅ **Your answer is correct.**  
- Should be configurable per market (e.g., max SMS/email/phone attempts per day/week).  
- Suggestion: Add **channel‑wise caps** (SMS vs. call vs. email) and **cool‑off periods**.  
- Example config:
  ```yaml
  contact_caps:
    IN:
      sms_per_day: 3
      calls_per_week: 5
    EU:
      sms_per_day: 2
      calls_per_week: 3
  ```

---

## 🏗️ Developer Takeaway
- All four areas should be **externalized in config files** (YAML/JSON).  
- Support **market‑specific overrides** and **audit trails**.  
- Add **validation schemas** to prevent misconfiguration.  
- Ensure **role‑based approval workflows** for sensitive actions (write‑off, commission changes).

---
Some refernce option:
covering all four parameters (bucket/strategy, agency formats, write‑off policy, regulatory contact caps) with **India, EU, and UAE** included. This enforces consistency across markets:

```json
{
  "$schema": "http://json-schema.org/draft-07/schema#",
  "title": "CollectionRecoveryConfig",
  "type": "object",
  "properties": {
    "bucket_strategy_matrix": {
      "type": "object",
      "description": "Defines repayment bucket/strategy order per product or globally",
      "patternProperties": {
        "^[A-Z]{2}$": {
          "type": "array",
          "items": { "type": "string" }
        }
      }
    },
    "agency_config": {
      "type": "object",
      "description": "Agency file formats and commission terms",
      "patternProperties": {
        "^[a-zA-Z0-9_]+$": {
          "type": "object",
          "properties": {
            "file_format": { "type": "string", "enum": ["CSV", "XML", "JSON"] },
            "commission": { "type": "string" }
          },
          "required": ["file_format", "commission"]
        }
      }
    },
    "writeoff_policy": {
      "type": "object",
      "description": "Write-off DPD thresholds, approval matrix, IFRS9 staging",
      "patternProperties": {
        "^[A-Z]{2}$": {
          "type": "object",
          "properties": {
            "dpd_threshold": { "type": "integer", "minimum": 30 },
            "approval_matrix": {
              "type": "array",
              "items": { "type": "string" }
            },
            "ifrs9_stage": { "type": "string", "enum": ["Stage1", "Stage2", "Stage3"] }
          },
          "required": ["dpd_threshold", "approval_matrix", "ifrs9_stage"]
        }
      }
    },
    "contact_caps": {
      "type": "object",
      "description": "Regulatory contact attempt caps per market",
      "patternProperties": {
        "^[A-Z]{2}$": {
          "type": "object",
          "properties": {
            "sms_per_day": { "type": "integer", "minimum": 0 },
            "calls_per_week": { "type": "integer", "minimum": 0 },
            "emails_per_week": { "type": "integer", "minimum": 0 }
          }
        }
      }
    }
  },
  "required": ["bucket_strategy_matrix", "agency_config", "writeoff_policy", "contact_caps"]
}
```

---

### 🏷️ Example Config (India, EU, UAE)

```yaml
bucket_strategy_matrix:
  IN: [penalty_fees, past_due_interest, current_interest, principal]
  EU: [past_due_interest, current_interest, principal, fees]
  AE: [current_interest, principal, fees]

agency_config:
  agency1:
    file_format: "CSV"
    commission: "2%"
  agency2:
    file_format: "XML"
    commission: "tiered: [1%, 2%, 3%]"

writeoff_policy:
  IN:
    dpd_threshold: 180
    approval_matrix: ["branch_manager", "risk_head"]
    ifrs9_stage: "Stage3"
  EU:
    dpd_threshold: 360
    approval_matrix: ["risk_committee"]
    ifrs9_stage: "Stage2"
  AE:
    dpd_threshold: 150
    approval_matrix: ["regional_manager", "compliance_officer"]
    ifrs9_stage: "Stage3"

contact_caps:
  IN:
    sms_per_day: 3
    calls_per_week: 5
    emails_per_week: 2
  EU:
    sms_per_day: 2
    calls_per_week: 3
    emails_per_week: 1
  AE:
    sms_per_day: 2
    calls_per_week: 4
    emails_per_week: 2
```

---

✅ **Developer takeaway:**  
- Schema enforces structure and prevents misconfiguration.  
- Each market (IN, EU, AE) can override defaults.  
- Supports auditability and compliance across regions.  

---
