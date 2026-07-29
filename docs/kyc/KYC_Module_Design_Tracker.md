# KYC Module — Design & Implementation Tracker

> ## 📖 See `MMS_KYC_Feature_Reference.md` first (added 2026-07-29)
> That document is the current, complete reference on the same MMS system this
> tracker researched — it also covers the risk-scoring, document-annotation, and
> multi-provider-validation layers this tracker explicitly parked (§1, §9.2 below).
> The wallet-app redirect immediately below is itself now stale: platform-of-record
> reversed back to standalone vmu_core on 2026-07-23
> (`project_platform_of_record_vmu_core`). Placement is an open question again —
> see the new doc's §8 — not silently resolved by re-reading this note.

> ## ⚠️ SUPERSEDED (2026-07-14) — kept for the reasoning trail, not deleted
> **This vmu_core-side design was reversed the same day it was written.**
> The placement decision in §0 below missed a real, checkable fact:
> vmu_core has **no customer-facing or merchant-facing UI at all**
> (confirmed via its router — only `/visionplus/admin/*` operator routes
> and machine-to-machine APIs). Every real consumer of a KYC *form* is a
> person who needs somewhere to fill it out, and wallet-app is the only
> repo with that UI. The module is now being built in wallet-app instead,
> extending its existing (if bare-bones) `WalletCompliance.KycCase`
> system. **See the real, current design at
> `wallet-app/docs/kyc-module-design-tracker.md`.** This file is kept
> only so the placement reasoning (including where it went wrong) isn't
> lost.
>
> New module (A3.4/A3.5 in `docs/shared/NEW_PRODUCTS_PROGRAM_TRACKER.md`,
> previously parked). Modeled after a working reference implementation in
> the sibling `MerchantManagementSystem` (Laravel) repo — researched
> before designing anything here, not guessed. Same convention as
> wallet-app's `wps-ui-screen-flow-tracker.md`/`prepaid-ui-screen-flow-tracker.md`:
> one doc carries both the design and the phase tracker.
>
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending` · `🔒 Blocked`

---

## 0. Placement decision — vmu_core, not wallet-app (answered 2026-07-14)

wallet-app already has a real, working KYC case system
(`apps/wallet_compliance`: `KycCase` state machine `submitted →
under_review → approved/rejected/expired`, `SubmitKycCase`/
`ReviewKycCase` commands, a real `kyc_cases` table, admin `KycCasesLive`,
customer `KycLive`) — but it's **fixed-shape**: `kyc_type` is a bare
`:kyc | :kyb` atom, `evidence_refs` a list of URLs, `metadata` an
unvalidated free-form map. No form builder, no method concept, no
per-product configuration exists in *either* repo.

**Decision: build in vmu_core, as a new module, API-first.** Two reasons,
not arbitrary:
1. The ops-plan's own **Q4/Q5 answer** ("wallet-app = UI layer, vmu_core
   = APIs") — a cross-product KYC engine every product family needs
   (Fleet, Virtual Cards, Prepaid, BNPL, WPS workers) is exactly the
   shared-capability shape that decision implies belongs in vmu_core,
   consumed by wallet-app's products as an API client (same pattern as
   A1's `/api/v1/*`).
2. It sits directly beside the **Party Registry** (A3.1) — the actual
   cross-repo identity hub. `Party.ProductLink.product_family` already
   exists as exactly the "which product" tag this module needs, and
   `Party.KycAttainment` already exists as the outcome record a KYC
   approval should write to — this module completes something already
   half-built, rather than starting a parallel system.

wallet-app's existing `KycCase` is **not touched or replaced** by this
phase — it keeps working for whatever already depends on it. Products
that want the new dynamic-form capability call the new vmu_core API.

---

## 1. What the reference implementation actually does (researched, not guessed)

Confirmed via reading `MerchantManagementSystem`'s real controllers/
models/migrations/views (not assumed from the name):

- **`kyc_methods`** = a form *template*. Fields are a JSON array stored
  directly on the row (`fields` column) — no child "kyc_fields" table.
  16 field types (text/number/email/tel/textarea/file/select/radio/
  checkbox/date/url/password/hidden/divider/heading/**group** —
  repeatable sub-field groups, e.g. "Authorized Signatories") defined in
  a config file (`config/forms.php`), not a DB table. A real drag-reorder
  builder UI (`admin/js/kyc-builder.js`, jQuery-UI sortable) lets an
  admin add/remove/reorder fields and set label/type/options/validation/
  required per field, entirely at runtime — genuinely dynamic, not a
  fixed set of toggleable presets.
- **`kyc_requests`** = one submission per applicant, storing a **frozen
  snapshot** of the method's fields at submission time (`fields` column
  on the request) *plus* the answered `data` (values keyed by field
  name) — so a later edit to the method template never corrupts a past
  submission's record of what was actually asked.
- **Conditional logic**: rules (`{target_field, condition: {field,
  operator, value}}`, operators `equals/not_equals/contains/
  greater_than/less_than/is_empty/is_not_empty/in_array`) stored as JSON
  on the method, evaluated by a pure function.
- **OCR + third-party validation**: config (enabled flag, provider
  config, field↔provider mapping) stored as JSON on the method; actual
  processing delegated to pluggable provider services.
- **The one real weakness, worth improving on**: per-product reuse is a
  bare `onboarding_type` enum (`user`/`admin`/`loan`), and rather than
  reusing the mechanism cleanly, the "loan" product **forked its own
  separate table and controller** (`loan_kyc_requests` +
  `LoanKycController`) with an even narrower field-type whitelist —
  duplication dressed as reuse. A route hints at an abandoned attempt at
  a cleaner per-product requirement toggle (`KycMethodRequirementController`
  — referenced in routes, the controller class doesn't exist).
- **LSEG screening, country-risk tiers, and credit scoring** are real but
  **separate, adjacent** concerns layered on top of KYC data — not part
  of the core form/queue mechanism. **Explicitly out of scope for this
  module** (matches A3.5's original "market-gated, plan separately"
  framing) — not silently folded in.

## 2. The one deliberate improvement over the reference

**A single, shared `kyc_requests` table for every product** — `KycMethod`
carries a `product_scope` string tag (free text, not a fixed enum column
requiring a migration for every new product), but there is exactly one
request/submission schema regardless of which product it's for. No
per-product table forking. `product_scope`'s vocabulary is expected to
line up with `Party.ProductLink.product_family` (already real: "this
party has a wallet-app user record" style tags) so a KYC request can
optionally resolve straight to the `Party`/`ProductLink` it's for.

## 3. Schema design

### 3.1 `kyc_methods` — the form template
| Field | Type | Notes |
|---|---|---|
| `method_id` | binary_id PK | |
| `name` | string | internal/admin-facing name |
| `title` | string | shown to whoever fills the form |
| `product_scope` | string | e.g. `"hcs_fleet_company"`, `"wallet_prepaid"`, `"wallet_bnpl_borrower"`, `"wps_worker"`, `"generic"` — free text, matches `ProductLink.product_family`'s vocabulary where applicable |
| `status` | string | `active`/`inactive` |
| `version` | integer | incremented on every field-set edit — belt-and-suspenders alongside the request's own frozen snapshot |
| `fields` | map (JSON) | array of field defs — see §3.2 |
| `conditional_rules` | map (JSON), nullable | §3.4 |
| `ocr_enabled` | boolean | |
| `ocr_config` | map (JSON), nullable | which fields trigger OCR extraction, expected document type |
| `third_party_validation_enabled` | boolean | |
| `provider_field_mapping` | map (JSON), nullable | which external provider validates which field |
| `sys_id` / `bank_id` | string, nullable | Module-Config-style scoping, matching how `Party.ConfigCatalog` scopes `identifier_hierarchy` — a bank can have its own method per product |

### 3.2 Field definition shape (inside `kyc_methods.fields`)
```
%{
  "key" => "passport_number",       # stable identifier, used in data/validation/conditional rules
  "label" => "Passport Number",
  "type" => "text",                 # see VmuCore.Kyc.FieldTypes — fixed Elixir catalog, not DB-editable
  "required" => true,
  "order" => 3,
  "options" => [],                  # for select/radio/checkbox
  "validation" => %{"min_length" => 6, "pattern" => "^[A-Z0-9]+$"},
  "group_fields" => nil             # populated only when type == "group" (repeatable sub-fields)
}
```
**Decision: field *types* are a fixed, compile-time Elixir catalog
(`VmuCore.Kyc.FieldTypes`), not a DB table** — matches the reference's
own `config/forms.php` (a config file, not a DB table either). Adding a
genuinely new *kind* of input widget is a code change; adding a new
*field instance* of an existing type is fully runtime-dynamic, exactly
matching the reference's real behavior.

### 3.3 `kyc_requests` — one shared submission table for every product
| Field | Type | Notes |
|---|---|---|
| `request_id` | binary_id PK | |
| `application_number` | string | human-friendly reference, auto-generated |
| `kyc_method_id` | FK | |
| `method_version` | integer | snapshotted at submission |
| `fields_snapshot` | map (JSON) | frozen copy of `kyc_methods.fields` at submission time (§1) |
| `party_id` | binary_id, nullable | FK to `parties` — set once resolved, may be `nil` at submission if the caller hasn't linked a Party yet |
| `product_link_id` | binary_id, nullable | FK to `party_product_links` |
| `external_subject_ref` | string, nullable | lets a caller submit before it has a Party at all — this module works standalone, not only through Party Registry |
| `data` | map (JSON) | answered values keyed by field `key` |
| `status` | string | `submitted \| under_review \| approved \| rejected \| expired` — **reuses wallet-app's richer, already-proven state machine shape**, not the reference's flat 0/1/2 |
| `reviewer_id` / `reviewer_source` / `decision_reason` | | |
| `submitted_at` / `reviewed_at` / `expires_at` | | |
| `correlation_id` | string | |

### 3.4 `kyc_documents` — uploaded files for `file`-type fields
`request_id`, `field_key`, `storage_path`, `original_filename`,
`content_type`, `ocr_result` (map, nullable), `ocr_provider`,
`uploaded_at`. Mirrors P-UI1/WPS's "local disk under `priv/`, path in a
DB column" storage decision — no new object-storage integration for v1.

### 3.5 `kyc_providers` — pluggable OCR / validation adapters
`provider_id`, `name`, `provider_type` (`ocr | screening |
identity_verification`), `config` (map — e.g. base URL), `status`.
`VmuCore.Kyc.ProviderAdapter` behaviour (`extract_text/1` for OCR,
`validate_field/2` for identity/screening providers) + one real
implementation now: `VmuCore.Kyc.Adapters.OcrHttpAdapter`, wired to the
**real, already-running** OCR server —
```
POST http://localhost:4000/api/detect_text
  -F "image=@<file>" [-F "model_type=tesseract_ocr|paddle_ocr|keras_ocr"]
  → 200 %{filename:, simplified_text: %{groupings:, raw_text:}}
```
via `Req`, matching how `ASM.OidcClient`/others in this codebase already
use `Req` for outbound HTTP. No screening/identity-verification provider
is built now — the behaviour exists so one can be added later without
touching the core module (matches A3.5's original "market-gated adapter"
framing).

## 4. Approval writes to the Party Registry — the real integration point

On `approve`, if `party_id`/`product_link_id` are set on the request, the
module calls `Party.Registry`-adjacent logic to **upsert a
`Party.KycAttainment`** row: `party_id`, `product_link_id`, `tier`
(derived from the method, e.g. `method.name`), `flow_used` (the method's
`method_id`/`name` — that field already exists on `KycAttainment` and was
unused until now), `attained_at: now()`, `status: "VALID"`. This is the
one thing the reference implementation never had a clean equivalent of —
its "completion" tracking lived as ad-hoc columns on the `users` table.
If no `party_id` is set on the request, the attainment write is skipped
(not an error) — a caller can use this module for the form/review
mechanism alone without opting into Party Registry linkage.

## 5. Conditional logic

Ported 1:1 from the reference's real rule shape:
`%{"target_field" => key, "condition" => %{"field" => key, "operator" =>
op, "value" => v}}`, operators `equals/not_equals/contains/greater_than/
less_than/is_empty/is_not_empty/in_array`. `VmuCore.Kyc.ConditionalLogic.
evaluate/2` — pure function, `(rules, submitted_data) -> [visible_field_keys]`,
no persistence of its own.

## 6. Admin UI — vmu_core's existing ASM console, not a new route tree

Follows the exact same pattern HCS/COL already use in `AdminLive`
(`lib/vmu_core_web/live/admin/admin_live.ex`): a new `"kyc"` module key,
sidebar entry, `RolePermission` grants, dispatched as a `live_component`
— not a separate LiveView/router tree.

| Screen | What it does |
|---|---|
| Methods list/builder | List methods (filter by `product_scope`/status). "+ New Method" → dynamic field builder: add/remove/reorder fields, pick type from the fixed catalog, set label/required/options/validation, configure conditional rules, toggle OCR/provider mapping. |
| Requests queue | List/filter by status/method/product_scope. Detail view: submitted `data` rendered against `fields_snapshot` (so it always renders correctly even if the live method has since changed), uploaded documents + their OCR results, Approve/Reject (writes `KycAttainment` per §4). |
| Party KYC tab | A new tab on the existing Party detail view (if one exists — check at implementation time) or a simple query screen: every `KycAttainment` + `kyc_requests` history for a given `party_id`. |

## 7. API layer (`vmu_core = APIs`)

Follows A1/A3.1's exact convention (`ServiceAccount` scope-gating,
`ErrorEnvelope`, `AuditLog.record`, `request_id` in `meta`):

| Endpoint | Scope | Purpose |
|---|---|---|
| `GET /api/v1/kyc/methods?product_scope=X` | `kyc:read` | Fetch the active method + field schema for a product — a caller (e.g. wallet-app) uses this to know what to ask for. **Rendering that schema into an actual dynamic form on wallet-app's side is real, separate work this phase does not build** — flagged, not assumed (§9). |
| `POST /api/v1/kyc/requests` | `kyc:write` | Submit a filled request (`kyc_method_id`, `data`, optional `party_id`/`product_link_id`/`external_subject_ref`). Snapshots `fields`/`method_version` server-side. |
| `GET /api/v1/kyc/requests/:id` | `kyc:read` | Status check. |
| `POST /api/v1/kyc/requests/:id/documents` | `kyc:write` | Upload a file for a `file`-type field; triggers OCR if the method has it enabled for that field. |

Review/approve/reject stays **admin-console-only** (no public API) —
matches how every other approval flow in this program (COL write-offs,
HCS facility-limit changes, WPS refunds) keeps the decision step inside
the admin surface, never exposed for a service account to call directly.

## 8. Phase breakdown

- **KYC-P1** — Core schema + method builder admin UI (no submissions yet): `kyc_methods`, `VmuCore.Kyc.FieldTypes`, `VmuCore.Kyc.Method` context, admin Methods screen.
- **KYC-P2** — Submission + review workflow: `kyc_requests`/`kyc_documents`, `VmuCore.Kyc.Request` context (submit/review/approve/reject state machine), admin Requests queue, `Party.KycAttainment` integration (§4).
- **KYC-P3** — Conditional logic engine + OCR provider adapter (real `localhost:4000` integration) + document upload/preview.
- **KYC-P4** — API layer (`/api/v1/kyc/*`), scope-gated, audited.

Full per-phase task tables written at the start of each phase (same
discipline as every other module this session) — not written speculatively
here before KYC-P1 actually starts.

## 10. Phase Tracker

### Phase KYC-P1 — Core Schema + Method Builder ⬜ Pending (design complete 2026-07-14)
| # | Task | File(s) | Status |
|---|---|---|---|
| KYC-P1.1 | Migration + schema: `kyc_methods` (§3.1) | new migration + `lib/vmu_core/kyc/method_schema.ex` (or equivalent Ecto schema module) | ⬜ |
| KYC-P1.2 | `VmuCore.Kyc.FieldTypes` — fixed catalog of supported field types + per-type validation-rule builder (§3.2) | `lib/vmu_core/kyc/field_types.ex` | ⬜ |
| KYC-P1.3 | `VmuCore.Kyc.Method` context — create/update/list/archive methods, field-array validation against the catalog, version bump on field-set edits | `lib/vmu_core/kyc/method.ex` | ⬜ |
| KYC-P1.4 | Admin `KycComponent` — Methods list + dynamic field builder, registered into `AdminLive`'s module dispatch/sidebar/`RolePermission` (§6) | `lib/vmu_core_web/live/admin/kyc_component.ex`, `admin_live.ex`, `role_permission.ex` | ⬜ |
| KYC-P1.5 | Live verification: create a method with several field types + a group field via the real UI → fields persist correctly → edit bumps `version` → an admin without the `kyc` module grant cannot see the screen | new test, real Postgres | ⬜ |

### Phase KYC-P2..4 — outline only, detailed at the start of each phase
Per §8: submission/review workflow + Party integration (KYC-P2),
conditional logic + OCR provider (KYC-P3), API layer (KYC-P4).

## 9. Open items / explicitly out of scope (flagged, not silently assumed)

1. **wallet-app-side dynamic form rendering.** If wallet-app products
   (Prepaid, BNPL) want to use this module's dynamic forms, wallet-app
   needs a renderer that consumes `GET /api/v1/kyc/methods` and draws
   the right input widget per field type — real, non-trivial UI work on
   the *other* repo, out of scope for this vmu_core-side build. v1's own
   admin console (§6) is enough to prove the mechanism end-to-end
   without that dependency.
2. **LSEG/sanctions screening, country-risk tiers, credit scoring** —
   confirmed real in the reference but a genuinely separate concern
   (§1). Not built here. A `screening` provider type exists in the
   adapter behaviour (§3.5) as a future extension point only.
3. **Multi-step forms** (the reference's `step` column) — not built in
   v1. Every method is a single-page form. Revisit if a real multi-step
   requirement shows up.
4. **KYC recognition across products** — `Party.ConfigCatalog`'s
   `kyc_recognition_rules` key already exists (whether product X may
   accept product Y's attainment instead of requiring a fresh one) but
   is currently always empty (`always fresh per product`). This module
   doesn't change that default; it just makes attainments real instead
   of a schema with nothing writing to it.
