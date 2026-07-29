# MMS KYC Management — Feature Reference (as built, production)

**Status:** 📖 Reference document — describes an existing, in-production system. This is
**not** a vmu_core build plan. Written 2026-07-29 at the user's request: the merchant
KYC screens in `MerchantManagementSystem` (Laravel, "MMS") are in live use today, the
customer and operations teams like the workflow, and it is the concrete reference to
design from the next time KYC work resumes in vmu_core — "it works well, but needs
some improvement," per the user.

**Relationship to `docs/kyc/KYC_Module_Design_Tracker.md`:** that doc already
researched this same MMS reference on 2026-07-14, but scoped narrowly to the
form-builder/submission mechanism and explicitly parked LSEG screening, risk scoring,
and document annotation as "separate concerns." It was marked SUPERSEDED the same day
because vmu_core had no customer-facing UI at the time, so the doc redirected the
build to wallet-app instead. **That redirect's premise is now stale** —
`project_platform_of_record_vmu_core` reversed platform-of-record back to standalone
vmu_core on 2026-07-23. This document is the complete, current reference (form
builder **and** the risk/compliance/annotation layers the old doc parked); the
placement question (vmu_core vs. elsewhere, and whether/how to reconcile with the
July-14 schema design) is deliberately left open at the end — a real architecture
decision, not something to re-settle inside a research doc.

Grounded entirely in reading the actual MMS code
(`MerchantManagementSystem/script/app/{Http/Controllers,Services,Observers,Models}`)
plus the seven screenshots the user attached of the live admin UI. Nothing here is
inferred from file/class names alone.

---

## 1. Where KYC sits in the merchant lifecycle

KYC is one stage among several in `MerchantStageService`'s onboarding pipeline:

```
Leads → Applications → Merchant Signoff → Store List → First Store →
All Stores → KYC → Switch Onboarding → Deployment → Live
```

A merchant's KYC is not a single form — it's a **sequence of `KycMethod`s** (each one
a numbered "step," e.g. step 1 = Business Profile, step 2 = KYC documents, step 3 =
Bank Details, step 4 = Location, step 5 = Document Signing), each producing its own
`KycRequest` submission. `StepBypassConfig` lets ops mark individual steps as
not-required globally (a per-step on/off toggle, not per-merchant).

---

## 2. Screens (from the attached screenshots + their controllers)

### 2.1 KYC Verification Methods list — `KycMethodController@index`
The method *catalog*. Screenshot shows 23 total methods, 16 active, 14
admin-managed vs. 6 self-onboarding. Table columns: title, document types (tag
chips), step number, OCR-preview icon, "Image Accept" Y/N, onboarding type badge,
created date, active/inactive status, edit action. Filters: onboarding type, status,
sort-by-step. A bulk "Allow Bypass" action opens `StepBypassConfig`'s modal
(`KycMethodController@getBypassConfig`/`saveBypassConfig`).

### 2.2 Edit KYC Verification Method — `KycMethodController@edit`, 4 tabs
This is the form builder, and it is genuinely dynamic at runtime (not a fixed set of
toggleable presets):
- **Form Fields** — add/remove fields; per field: label, an auto-derived
  immutable `name`/slug, type (from `config('forms.field_types')`), required
  flag, validation rules. `document_types` (multi-select tags — Emirates ID,
  Trade License, Business Registration, ...) drives what `kyc_document_types.php`
  offers for OCR/provider matching later.
- **Conditional Logic** — "Show Field X When Field Y <operator> <value>" rules,
  stored as JSON (`conditional_rules`), evaluated by
  `KycMethod::evaluateConditionalRules()`. Operators: equals, not_equals,
  contains, greater_than, less_than, is_empty, is_not_empty, in_array.
- **Third-Party Validation** — enable toggle, a grid of available providers
  (screenshot shows Signzy Enhanced Document Validator, Generic Bank Account
  Validator, Enhanced Multi-Engine OCR, Signzy UAE Emirates ID Validator, Signzy
  UAE Trade License Validator — all shown **Inactive** in the screenshot), and a
  per-field mapping UI (primary provider, fallback providers, confidence
  threshold, timeout).
- **OCR Configuration** — per-field: enable OCR, source document type, extraction
  method (keyword search / pattern / position), keywords/patterns, validation
  regex, data-cleaning rules (remove spaces, uppercase, format-as-date, ...), an
  "Auto Suggest" button, and a "Test OCR" action.

### 2.3 KYC Requests dashboard — `KycRequestController@index`
Two levels of counters: **request-level** (all/approved/pending/rejected/
re-submitted — screenshot: 2027/1925/102/0/0) and **customer-level**, grouped by
merchant and driven off `contract_approval_status`, not raw KYC status (screenshot:
216 total customers, 2 approved, 214 pending, 0 rejected). Each merchant row expands
to show every method they've submitted, with per-method status, note, document
count, submission date, and a "View" action. The list also carries merchant
contract approval (approve/reject) and risk-profile actions
(`approveContract`/`rejectContract`/`updateMerchantRiskProfile`) inline — contract
sign-off and risk tagging live on the same screen as KYC review, not a separate one.

### 2.4 Document Viewer — `DocumentPreviewController@documentViewer`
Full annotation workspace: side-by-side document list + viewer, `Generate Report`.
The screenshot for KYC Request #3728 shows **"Documents (0)" / "No file upload
fields found in this KYC method."** — traced to real code, not a bug in the sense
of a crash: `extractDocumentFieldsFromData()` only surfaces fields typed `file` on
the method (or file-shaped values in the submitted `data`). Methods used purely for
OCR-driven *text* capture (e.g. "Business Information," which the edit screenshot
shows is all text-input fields) correctly have nothing to show here. It's a real
UX confusion point for ops, though — the empty state doesn't say *why* (this method
has no document fields) versus *the documents are just missing*, and an ops user
can't tell the difference without checking the method definition separately.

---

## 3. Data model (as it actually exists)

| Table | Role |
|---|---|
| `kyc_methods` | Form **template**. `fields` (JSON array, no child table), `step`, `onboarding_type` (`user`/`admin`/`loan`), `document_types`, `conditional_logic_enabled`/`conditional_rules`, `ocr_enabled`/`ocr_config`, `third_party_validation_enabled`/`field_provider_mapping`/`provider_validation_rules`. |
| `kyc_requests` | One submission per applicant per method. `data` (answered values), `status` (0 pending / 1 approved / 2 rejected / 3 re-submitted), `kyc_application_number` (auto-generated, unique), `ocr_status`/`ocr_data`/`ocr_confidence`. |
| `loan_kyc_requests` + `LoanKycController` | A **separate, forked** table + controller for the `loan` onboarding type, with its own narrower field-type whitelist, instead of reusing `kyc_requests` with a scope filter. Confirmed real duplication (also flagged in the July-14 tracker). |
| `kyc_third_party_providers` | Provider catalog used by the **admin-configured per-field** validation layer (§4.1). |
| `validation_providers` + `third_party_validation_results` | A **second, separate** provider catalog + results table used by `KycRequestController`'s ad-hoc "Validate"/"Bulk Validate" actions and `ValidationServiceFactory` (§4.1) — not the same rows as `kyc_third_party_providers`. |
| `lseg_field_settings` / `lseg_secondary_fields` | A **third** provider-adjacent system: per-`KycMethod` mapping of KYC field → LSEG API key, managed on its own settings page (§4.2). |
| `step_bypass_config` | Global per-step required/optional toggle. |
| `ocr_suggestion_data` | Per-user/step/method OCR extraction cache, merged (not overwritten) across repeated OCR runs. |
| `document_annotations` | Comment/highlight/approval/rejection/correction/verification marks on individual documents, keyed by KYC request + field + document id. Rejection annotations trigger an automatic rejection email with the flagged document attached. |
| `merchant_risk_scores` | Computed risk category (`LOW`/`MEDIUM`/`HIGH`/`TERMINATED`) with per-factor sub-scores (jurisdiction, txn volume, ownership, business model, PEP, adverse media, ...). |
| `signzy_document_responses`, `lseg_document_responses`, `lseg_ongoing_screening_updates`, `signzy_api_field_responses`, `signzy_emirate_report_document_responses` | Raw third-party API response logs, one row per real call made during the *customer-facing* onboarding flow (§4.3) — distinct again from `third_party_validation_results` above. |

---

## 4. Third-party validation & OCR — four parallel systems, not one

This is the single biggest thing worth knowing before designing a cleaner version:
**there are four independently-built subsystems that all do "call an external
provider and validate a document/field,"** built at different times without being
consolidated. All four are real and (mostly) functioning, not dead code — but a
newcomer reading only the admin UI would not realize the "Third-Party Validation"
tab (§2.2) is not the same mechanism that actually validates a customer's Emirates
ID during onboarding.

### 4.1 Admin-configured per-field provider validation (the newest layer)
`KycThirdPartyProvider` (config catalog) + `KycProviderConfigurationService`
(field↔provider mapping, cached 1h) + `KycFieldValidationService` (executes
validation via `ThirdPartyValidationService`, with fallback-provider retry and a
30-min result cache) + `ValidationServiceFactory`/`BaseValidationService` (a
**second**, parallel provider abstraction — `ValidationProvider` model, not
`KycThirdPartyProvider`) driving `SignzyUAEValidationService`/`LSEGValidationService`
for `KycRequestController`'s "Validate"/"Bulk Validate" buttons on a request's Show
page. This is the layer the Edit-Method screenshot's "Third-Party Validation" tab
configures — and every provider in that screenshot's card grid shows **Inactive**,
meaning as configured today this layer is present in the UI but not live.

Two real gaps in this layer:
- `KycProviderConfigurationService::testProviderConfiguration()` — the actual
  provider call is a `// TODO: Implement actual provider testing`; today it only
  validates that required config keys are present. The "Test Configuration" and
  "Test All" admin buttons (`KycProviderController@testAll`) currently can't catch
  a real integration failure (wrong API key, unreachable endpoint), only a missing
  field.
- `KycProviderConfigurationService::getProviderUsageStats()` returns **literal
  `rand()` mock data** (request counts, success rate, daily usage) — the Provider
  Show page's usage statistics panel is fabricated, not telemetry. Worth fixing
  before anyone relies on it operationally.

### 4.2 LSEG field-mapping (a third, adjacent system)
`LsegFieldSetting`/`LsegSecondaryField` + `LsegFieldMappingService` +
`LsegSettingsController`, reachable from its own settings page
(`admin/lseg-settings`), map a `KycMethod`'s fields to specific LSEG API keys
(`kyc_field_name` → `lseg_api_key`, with per-field type/required/default/
transformation rule). This does not go through `LSEGValidationService` (§4.1) at
all — it configures the **live** call made from `UserKycApplicationController`
(§4.3).

### 4.3 The real, live integration (customer-facing, not admin-facing)
The actual Signzy and LSEG API calls that run **during a merchant's real
onboarding** live directly inside `User/UserKycApplicationController`
(2,055 lines) — `signzyDoc`/`signzyDocResponse`, `emirateIdReportSignzyApiCall`,
`lsegApiCall`, `lsegOngoingScreeningUpdates`, `generateLsegReport`. This is the
production-critical path; §4.1's factory/service classes are a newer,
better-structured abstraction that the admin's ad-hoc "Validate" button uses, but
it is not what runs automatically when a customer submits their Emirates ID.
Anyone touching Signzy/LSEG behavior needs to know both paths exist.

### 4.4 Document-level OCR field validators (`Services/ValidationProviders/*`)
A fourth hierarchy (`ValidationProviderInterface`/`BaseValidationProvider`) —
`SignzyUaeDocumentValidator`, `GovernmentIdValidator`, `BankAccountValidator`,
`CompanyRegistrationValidator`, `DriverLicenseValidator`, `PassportValidator`, plus
Signzy-specific Aadhaar/PAN/GST/bank/face-match/document-OCR validators — mostly
OCR-extract-then-regex-validate-format, with an optional live government/bank API
cross-check. **Two confirmed real bugs found while reading this layer:**
- `Services/ValidationProviders/Signzy/SignzyUaeDocumentValidator.php`'s
  `validateUaePassport()`/`validateUaeVisa()` methods are type-hinted against
  `ValidationRequest $request` and return `ValidationResult` — **neither class
  exists anywhere in the codebase.** Every other method in the same file uses
  plain arrays, and `validate()` calls these two the same way (`$this->
  validateUaePassport($data)` with an array). This is a broken/dead code path:
  if a KYC method is ever configured to validate `uae_passport` or `uae_visa`
  through this provider, it will fatal-error at runtime (TypeError on the
  parameter), not just under-perform.
- The same file's `performOcr()` references `$this->baseUrl`, which is never set
  anywhere — the constructor (and its parent `BaseValidationProvider`) only sets
  `$this->apiUrl`. Every OCR call in this validator concatenates `null . $endpoint`.
- `Services/KYC/Validators/SignzyUaeDocumentValidator.php` — a **completely empty
  file** (0 bytes), sitting in a different namespace but with the exact same class
  name as the real one above. An abandoned earlier attempt, left in place. It
  isn't autoloaded by anything today, but it's a landmine for a future
  find-and-open.

### 4.5 OCR extraction itself — also three parallel implementations
- `OcrService` — simple Tesseract wrapper + hand-written regex parsers for
  trade-license/passport/Emirates-ID text (`parseBusinessInfo`/
  `parsePersonalInfo`), used ad-hoc.
- `OcrDocumentProcessor` — the one actually wired to the admin OCR Configuration
  tab (`OcrController`). Runs Tesseract, maps text to fields using each method's
  `ocr_config` (keyword/pattern/position + fuzzy keyword matching for OCR typos),
  writes results into `OcrSuggestionData` (merged across runs, not overwritten).
  This is the real, in-use OCR path.
- `OCR\AdvancedOCRService` — a more sophisticated later build: pluggable engines
  (Tesseract/Google Vision/AWS Textract/Azure Form Recognizer), image
  preprocessing (deskew/denoise/contrast/sharpen), multi-engine fallback with
  confidence merging. **No controller or service in the codebase constructs or
  calls `AdvancedOCRService`** — it appears to be built but not wired into any
  screen. Worth confirming with the team whether it's mid-rollout or abandoned
  before building on top of it.

---

## 5. Risk scoring — real, but decoupled from the KYC approve/reject action itself

`MerchantRiskScoringService::computeScore()` produces a `MerchantRiskScore` with
category `LOW`/`MEDIUM`/`HIGH`/`TERMINATED` from sub-scores (jurisdiction, txn
volume, ownership, business model, PEP, adverse media, sanctions, ...), each
category mapping to an action + revalidation window (`auto_approved`/18mo,
`compliance_review`/12mo, `edd_required`/6mo, `terminated`/none).

Two model observers auto-*recompute* an existing score when relevant data changes:
- `KycRequestRiskScoreObserver` — fires when a KYC request tied to one of four
  specific method IDs (8=Country of Incorporation, 12=Annual Turnover,
  22=Shareholders/UBO, 23=Business Products — hard-coded method IDs, not a
  flag on the method) is approved or its data changes.
- `LSEGDocumentResponseRiskScoreObserver` — fires on every new/updated LSEG
  screening result; logs a `critical` alert if the new category is
  `TERMINATED` (sanctions match) and `warning` for PEP/adverse-media hits
  (both currently log-only — the `// TODO: Send immediate alert to compliance
  team` comments are still TODOs).

**Both observers explicitly do nothing if the merchant has no existing
`MerchantRiskScore` row yet** ("no previous risk score, don't auto-compute yet ...
will be computed manually when needed"). That means a merchant can complete every
relevant KYC step and never receive an *initial* risk score unless an admin
manually triggers one once — the automatic recomputation only kicks in
*after* that first manual score exists. Confirmed by reading the observer code,
not inferred.

The hard-coded method IDs (8/12/22/23) are also a fragile coupling: if someone
edits or reorders `kyc_methods` rows in a way that changes which id holds
"Shareholders/UBO," risk recomputation silently stops firing for that method with
no error anywhere.

---

## 6. What's genuinely good here (worth keeping, not just critiquing)

- **The form builder is real, not a facade.** Field types, ordering,
  required/validation rules, conditional visibility, OCR config, and provider
  mapping are all runtime-editable through the UI shown in the screenshots — no
  code deploy needed to add a new KYC step or change what a step asks for.
- **Frozen submission snapshots** aren't fully implemented as a first-class
  concept (no dedicated `fields_snapshot` column was found on `kyc_requests` in
  the controllers read) but `kyc_requests.data` plus the OCR/annotation trail
  gives a workable audit record per submission.
- **Document annotation is a real reviewer workflow**, not just approve/reject —
  per-document comment/highlight/approval/rejection/correction/verification marks,
  with automatic rejection-email-plus-attachment on a rejection annotation, and an
  approval-summary rollup (`generateApprovalSummary`) grouped by field.
- **The merchant-grouped Requests dashboard** (§2.3) — reviewing by merchant
  (with all their per-step submissions inline) rather than a flat request list is
  a sensible operational shape that a purely per-request queue would lose.
- **OCR-driven field suggestion with fuzzy keyword matching** genuinely helps with
  real-world OCR noise (`fuzzyKeywordMatch`/`fuzzyWordMatch` tolerate partial/typo
  matches), and results merge across repeated scans instead of clobbering earlier
  extractions.

---

## 7. Summary of concrete "needs improvement" items found

| # | Item | Where | Impact |
|---|---|---|---|
| 1 | `validateUaePassport`/`validateUaeVisa` reference non-existent classes | `Services/ValidationProviders/Signzy/SignzyUaeDocumentValidator.php` | Fatal error if ever invoked for passport/visa doc types |
| 2 | `$this->baseUrl` undefined (should be `$this->apiUrl`) | same file, `performOcr()` | Broken OCR endpoint URL for this validator |
| 3 | Empty duplicate class file, same name, dead namespace | `Services/KYC/Validators/SignzyUaeDocumentValidator.php` | Landmine for future maintainers, no functional impact today |
| 4 | Provider config "test" never calls the real provider | `KycProviderConfigurationService::testProviderConfiguration` | False confidence — can't catch real integration breakage |
| 5 | Usage stats are fabricated (`rand()`) | `KycProviderConfigurationService::getProviderUsageStats` | Provider Show page shows fake numbers as if real |
| 6 | Loan KYC forks its own table/controller instead of reusing `kyc_requests` | `loan_kyc_requests`, `LoanKycController` | Duplicated logic, two places to fix the same bug |
| 7 | Four independent "validate a document/field via provider" systems (§4.1–4.4) | across `Services/{KYC,Validation,ValidationProviders}` | Hard to know which layer actually runs live; the admin-configured layer (§4.1, screenshot) is not the one used in production onboarding (§4.3) |
| 8 | Three independent OCR implementations, one seemingly unwired | `OcrService`, `OcrDocumentProcessor`, `OCR\AdvancedOCRService` | `AdvancedOCRService`'s multi-engine/preprocessing work may be dead weight or a stalled rollout — needs confirming with the team |
| 9 | Risk score never auto-computed on *first* KYC approval, only recomputed after a manual first score | `KycRequestRiskScoreObserver`, `LSEGDocumentResponseRiskScoreObserver` | A merchant can finish KYC with no risk category unless ops manually triggers one |
| 10 | Sanctions/PEP/adverse-media alerts are log-only | `LSEGDocumentResponseRiskScoreObserver` | `// TODO: Send immediate alert to compliance team` — a `TERMINATED` sanctions match today produces a `Log::critical` line, not a notification |
| 11 | Risk-relevant method IDs are hard-coded (8/12/22/23) | `KycRequestRiskScoreObserver::$relevantMethods` | Silently stops working if those `kyc_methods` rows are ever edited/reordered |
| 12 | Document Viewer's empty state doesn't distinguish "this method has no document fields" from "documents are missing" | `DocumentPreviewController::documentViewer` (matches the attached #3728 screenshot) | Ops confusion — can't tell the two cases apart from the UI alone |
| 13 | `Api/KycValidationController.php` exists but is a 0-byte empty file | `app/Http/Controllers/Api/KycValidationController.php` | An API surface for KYC validation was started and never built — notably the same gap vmu_core's own KYC-P4 phase (API layer) hasn't started either |

---

## 8. Open questions (not answered here — flagged for the next planning conversation)

1. **Placement**, per the note at the top: does KYC work resume in vmu_core (per the
   current, reversed platform-of-record decision), and if so, does it reuse/extend
   the July-14 `KYC_Module_Design_Tracker.md` schema design (§3 there), or does that
   design need revisiting now that this document surfaces the risk-scoring/
   annotation/multi-provider layers it explicitly parked?
2. Is `AdvancedOCRService` (item #8 above) a deliberate future direction the MMS
   team intends to finish wiring, or dead code safe to ignore as a reference?
3. Should a rebuilt version consolidate the four validation systems (§4.1–4.4) into
   one, or is the layering (admin-configurable mapping vs. hard-coded production
   integration) intentional and just under-documented?
