# KYC Module — Implementation Tracker (native vmu_core build)

**Status:** 🔄 In progress, started 2026-07-29. Supersedes `KYC_Module_Design_Tracker.md`
(2026-07-14, itself marked superseded same day — see the note at its top). Read
`MMS_KYC_Feature_Reference.md` first for the full reasoning behind the mechanism
shape; this doc is the schema + phase plan for actually building it here.

---

## 0. Why build fresh here, not port Avenza's `wallet_kyc`

Avenza's `apps/wallet_kyc` (built 2026-07-14/15/16, per its own tracker) is a real,
complete, well-tested dynamic form-builder KYC engine — field types, conditional
logic, OCR adapter, versioned templates, live-wired admin + customer screens. The
engineering is sound. **The scope is wrong for this repo**: `product_scope` is a
free-text field covering only wallet-app's own products (`customer_kyc`,
`wallet_prepaid`, `wallet_bnpl_borrower`, `wps_worker`...) — zero concept of
vmu_core's actual card products (Credit/Debit/Prepaid/Fleet/Corporate/HCS), and it
never bridges to a cross-product record (no Party Registry access from wallet-app).
Not ported. Confirmed via direct code search, not assumed from the tracker's own
claims.

## 1. Two more things this build corrects that the July-14 tracker got wrong

1. **`Party.KycAttainment` doesn't exist in standalone vmu_core.** The July-14 plan
   assumed a Party Registry bridge that only ever existed in the (no-longer-
   platform-of-record) Avenza umbrella. This build anchors on what's actually here:
   `VmuCore.CMS.Arrangement` (customer_id + product_type + account_ref, already the
   real cross-product index — see `docs/cms/core-domain-new-docs.md`) and
   `VmuCore.Shared.Customer`.
2. **vmu_core already has five independent, duplicated `kyc_status` flags** —
   `Shared.Customer`, `CMS.DebitAccount`, `CMS.PrepaidAccount`, `CMS.WalletAccount`,
   `HCS.Company` each carry their own `kyc_status`/`kyc_verified_at`
   (PENDING/VERIFIED/REJECTED), each set by that product's own "KYC Verify/Reject/
   Reset" quick-action button (Debit/Prepaid/Wallet/HCS Card Products UX Parity
   work, and the base Customer screen) — no shared mechanism, no form, no document,
   no request record behind any of them. This module becomes the **system of
   record**; those five fields become a **synced read-model** the new module
   updates on approval (§5), not a second parallel system. The four existing
   admin screens are not rewritten in this phase — they keep reading the same
   field, it just becomes accurate because something real now writes it.

## 2. Architecture (confirmed with the user 2026-07-29)

- **One shared mechanism** for every product: `kyc_methods` (form template) +
  `kyc_requests` (submission) + `kyc_documents`. Never forked per product — that
  was the MMS reference's own Loan mistake (`loan_kyc_requests` + its own
  controller), not repeated here.
- **`product_type` is validated against `CMS.Arrangement.product_types()`**
  (`CREDIT DEBIT PREPAID CORPORATE_FACILITY CORPORATE_EMPLOYEE CORPORATE_FLEET
  WALLET`) — the same live taxonomy every other product already registers into.
  Not free text (wallet_kyc's actual mistake).
- **"Copy to a new product" = clone the method template** (`Kyc.Method.clone/2`)
  into a new `product_type`, recorded via `cloned_from_method_id` for traceability.
  Never a live shared reference between products.
- **Submissions are always separate per product + customer** — no cross-product
  answer reuse. Matches `Party.ConfigCatalog.kyc_recognition_rules`'s existing
  default in the July-14 doc's own framing ("always fresh per product"); this
  build doesn't need that key at all since Party doesn't exist here, but the
  behavior is the same by construction (one `kyc_requests` row is always scoped
  to one product_type).
- **Approval writes back** to whichever of the five existing flat fields matches
  the request's `product_type` (§5) — the real integration point, replacing the
  July-14 plan's nonexistent Party bridge.

## 3. Schema

### 3.1 `kyc_methods` — form template
| Field | Type | Notes |
|---|---|---|
| `method_id` | binary_id PK | |
| `name` | string | admin-facing |
| `title` | string | shown to whoever fills the form |
| `product_type` | string | validated against `CMS.Arrangement.product_types()` |
| `status` | string | `active`/`inactive` |
| `version` | integer | bumped on every field-set edit |
| `fields` | json | array of field defs, §3.2 |
| `conditional_rules` | json, nullable | §3.4-equivalent, ported from the reference's real rule shape |
| `cloned_from_method_id` | binary_id, nullable | set when created via "clone to new product" |
| `sys_id` / `bank_id` | string, nullable | Module-Config-style scoping, matches every other product's config cascade |

OCR/third-party-provider config columns deliberately **not** added in P1 — MMS's
own four-parallel-systems mess (`MMS_KYC_Feature_Reference.md` §4) is exactly what
happens when this gets bolted on piecemeal. Added properly in KYC-P3 as one
mechanism, not before.

### 3.2 Field definition shape (inside `kyc_methods.fields`)
```
%{
  "key" => "passport_number",
  "label" => "Passport Number",
  "type" => "text",           # VmuCore.Kyc.FieldTypes — fixed catalog
  "required" => true,
  "order" => 3,
  "options" => [],             # select/radio/checkbox
  "validation" => %{"min_length" => 6, "pattern" => "^[A-Z0-9]+$"},
  "group_fields" => nil        # populated only when type == "group"
}
```
Field *types* are a fixed, compile-time catalog (`VmuCore.Kyc.FieldTypes`) — adding
a new kind of input widget is a code change; adding a new field instance of an
existing type is fully runtime-dynamic.

### 3.3 `kyc_requests` — one shared submission table for every product
| Field | Type | Notes |
|---|---|---|
| `request_id` | binary_id PK | |
| `application_number` | string, unique | auto-generated, human-friendly |
| `kyc_method_id` | FK | |
| `method_version` | integer | snapshotted at submission |
| `fields_snapshot` | json | frozen copy of the method's fields at submission time |
| `customer_id` | binary_id FK → `cms_customers` | required — matches every other product's admin-managed-onboarding pattern this session (customer search first) |
| `product_type` | string | validated against `CMS.Arrangement.product_types()` — the product this KYC is *for* |
| `arrangement_id` | binary_id, nullable FK → `cms_arrangements` | set once the actual account/product is opened; KYC often precedes that, so nullable |
| `data` | json | answered values keyed by field `key` |
| `status` | string | `submitted \| under_review \| approved \| rejected \| expired` |
| `reviewer_id` / `decision_reason` / `submitted_at` / `reviewed_at` / `expires_at` | | |

### 3.4 `kyc_documents` — uploaded files for `file`-type fields
`request_id`, `field_key`, `storage_path`, `original_filename`, `content_type`,
`ocr_result` (json, nullable), `uploaded_at`. Local-disk-under-`priv/` storage,
path in a DB column — same convention every other product in this codebase uses.

## 4. Conditional logic
Ported 1:1 from the MMS reference's real rule shape (already proven twice — MMS
Laravel, and Avenza's `wallet_kyc`):
`%{"target_field" => key, "condition" => %{"field" => key, "operator" => op,
"value" => v}}`, operators `equals/not_equals/contains/greater_than/less_than/
is_empty/is_not_empty/in_array`. `VmuCore.Kyc.ConditionalLogic.evaluate/2` — pure
function, no persistence of its own.

## 5. The real integration point — status sync on approval

`VmuCore.Kyc.StatusSync.sync/1`, called from `Kyc.Requests.approve/2` and
`reject/2`, dispatches on `request.product_type`. **Corrected during KYC-P2
implementation** after checking the real schemas — `CORPORATE_EMPLOYEE` is a
*person* (an employee is a `Shared.Customer` row; `EmployeeCard` has no
`kyc_status` field of its own), so it syncs `Customer`, not `Company`. Both
`CORPORATE_FACILITY` and `CORPORATE_FLEET` are company-level (`Arrangement.
account_ref` resolves straight to `Company.id` for FACILITY, or to
`FleetCard.id` → `company_id` for FLEET, per `CMS.Arrangements.enrich_group/2`'s
own real resolution logic) — both sync `HCS.Company`:

| `product_type` | Target row | How resolved |
|---|---|---|
| `CREDIT`, `CORPORATE_EMPLOYEE` | `Shared.Customer` | `request.customer_id` |
| `DEBIT` | `CMS.DebitAccount` | latest account for `request.customer_id` |
| `PREPAID` | `CMS.PrepaidAccount` | latest account for `request.customer_id` |
| `WALLET` | `CMS.WalletAccount` | latest account for `request.customer_id` |
| `CORPORATE_FACILITY` | `HCS.Company` | `request.arrangement_id` → `account_ref` = `Company.id` |
| `CORPORATE_FLEET` | `HCS.Company` | `request.arrangement_id` → `account_ref` = `FleetCard.id` → `company_id` |

Updates `kyc_status`/`kyc_verified_at` only — does not touch anything else on the
target row. If no matching row exists yet (KYC done before the account is opened),
sync is skipped, not an error — the `kyc_requests` row itself remains the record
of truth regardless.

## 6. Admin UI — vmu_core's existing ASM console
New `"kyc"` module key in `AdminLive` (same pattern as every other product this
session): sidebar entry, `RolePermission` grants, dispatched as a `live_component`.

| Screen | What it does |
|---|---|
| Methods list/builder | List methods (filter by `product_type`/status). Dynamic field builder: add/remove/reorder fields, pick type, set label/required/options/validation. "Clone to product" action. |
| Requests queue | List/filter by status/product_type. Detail: submitted `data` rendered against `fields_snapshot`, Approve/Reject (fires §5 sync). |

## 7. Phase breakdown

- **KYC-P1** — Schema + `FieldTypes` catalog + `Kyc.Method` context (create/update/
  list/clone/version-bump) + admin Methods list/builder UI.
- **KYC-P2** — `kyc_requests`/`kyc_documents` + `Kyc.Request` context (submit/
  review/approve/reject) + `StatusSync` (§5) + admin Requests queue.
- **KYC-P3** — Conditional logic engine + `VmuCore.Kyc.ProviderAdapter` behaviour
  (`extract_text/1` for OCR, `validate_field/2` for identity/screening) + one real
  OCR adapter wired to the real, already-running local OCR server (confirmed by
  user 2026-07-29, same server the July-14 tracker referenced):
  ```
  POST http://localhost:4000/api/detect_text
    -F "image=@<file>" [-F "model_type=tesseract_ocr|paddle_ocr|keras_ocr"]
    → 200 %{filename:, simplified_text: %{groupings:, raw_text:}}
  ```
  Third-party document/identity validation (Signzy-equivalent, LSEG-equivalent) is
  **architecturally open but not built** in P3 — the behaviour exists so a real
  provider can be plugged in later per-field without touching core, matching the
  user's explicit instruction: "keep multiple option open as per architecture ...
  we might need to depend on 3rd party provider ... so we can add other provider
  later as per need." This is exactly the one-mechanism version of MMS's four
  parallel systems (§4.1–4.4 of the feature reference) — one adapter behaviour,
  N implementations, not N competing frameworks.
  Also in this phase: document upload/preview + the document-annotation review
  workflow (comment/approval/rejection marks per document field) — confirmed
  in-scope by the user, ported from the MMS reference's genuinely good part
  (`MMS_KYC_Feature_Reference.md` §6).
- **KYC-P4** — Risk-scoring hook on approval — confirmed in-scope by the user.
  Check first whether vmu_core's CDM module already has a risk-scoring engine to
  hook into before designing a new one (CDM already does credit-application
  risk/sanctions scoring per prior session work) — don't assume a clone of MMS's
  `MerchantRiskScoringService` is needed without checking.
- **KYC-P5** — API layer (`/api/v1/kyc/*`), scope-gated, audited, so wallet-app or
  Kosa App can eventually consume method schemas — real, separate UI work on
  those repos, out of scope here.

## 8. Phase Tracker

### KYC-P1 — Core Schema + Method Builder ✅ Done 2026-07-29 (commit `3950d92`)
| # | Task | Status |
|---|---|---|
| P1.1 | Migration: `kyc_methods` | ✅ |
| P1.2 | `VmuCore.Kyc.FieldTypes` | ✅ |
| P1.3 | `VmuCore.Kyc.Method`/`Methods` context (create/update-with-version-bump/list/clone) | ✅ |
| P1.4 | Admin `KycComponent` — Methods list + builder + Clone-to-product, registered into `AdminLive`/`RolePermission` | ✅ |
| P1.5 | Real-Postgres verification + regression — 8/8 new tests, full suite 427 tests / same 10 pre-existing failures | ✅ |

### KYC-P2 — Submissions + StatusSync ✅ Done 2026-07-29
| # | Task | Status |
|---|---|---|
| P2.1 | Migrations: `kyc_requests` + `kyc_documents` | ✅ |
| P2.2 | `Kyc.Request`/`Kyc.Document` schemas + `Kyc.Requests` context (submit/start_review/approve/reject) | ✅ |
| P2.3 | `Kyc.StatusSync` (§5) — corrected mid-implementation after checking real schemas (CORPORATE_EMPLOYEE syncs Customer not Company; CORPORATE_FACILITY/FLEET sync Company via Arrangement.account_ref; Company.kyc_verified_at is :utc_datetime, the other four targets are :naive_datetime) | ✅ |
| P2.4 | Admin Requests tab — admin-initiated submission wizard (customer search → product → active method → dynamic form), queue, detail + Approve/Reject | ✅ |
| P2.5 | Real-Postgres + real-browser verification + regression — 12/12 new tests (9 context + 3 LiveView), full suite 439 tests / same 10 pre-existing failures | ✅ |

File-type fields accept a text reference for now (no real upload/preview yet —
that's KYC-P3 scope, not a gap in this phase). "group" (repeatable sub-fields)
isn't rendered in the submission form yet either, same reason.

**Next: KYC-P3** — conditional logic engine + `Kyc.ProviderAdapter` behaviour +
real local-OCR-server adapter + document upload/preview + document-annotation
review workflow (see §7 for the confirmed real OCR endpoint contract).

### KYC-P3..5 — outlined in §7, detailed at the start of each phase
