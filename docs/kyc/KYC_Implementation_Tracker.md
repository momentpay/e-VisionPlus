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

### KYC-P3 — Conditional Logic + OCR Adapter + Documents + Annotation ✅ Done 2026-07-29
| # | Task | Status |
|---|---|---|
| P3.1 | `VmuCore.Kyc.ConditionalLogic` (pure evaluator) + Method builder "Conditional Logic" section | ✅ |
| P3.2 | `VmuCore.Kyc.ProviderAdapter` behaviour + `Kyc.Adapters.OcrHttpAdapter` (real `localhost:4000/api/detect_text`, `Req.Test`-stubbed in tests, same convention as `NotificationDispatcher.HttpGateway`) | ✅ |
| P3.3 | Migration `kyc_document_annotations` + `Kyc.DocumentAnnotation` + `Kyc.Documents` context (upload to local disk + OCR + annotate) | ✅ |
| P3.4 | Request submission form applies `ConditionalLogic.visible_fields/3` live; Request detail gained a Documents panel (shared upload slot + field picker, same shape as `DpsComponent`'s evidence panel) with OCR preview + annotation trail | ✅ |
| P3.5 | Real-Postgres + real-browser verification + regression — 18/18 new tests (9 conditional logic, 2 OCR adapter, 5 documents context, 2 new LiveView flows), full suite 457 tests / same 10 pre-existing failures | ✅ |

Two real gotchas hit and fixed during implementation, not assumed correct from
docs: Req 0.5.18's multipart file value is `{data, filename:, content_type:}`,
not `{:file, path}`; `consume_uploaded_entries/3`'s callback must always return
`{:ok, <term>}` even when `<term>` is itself an `{:error, _}` tuple, or LiveView
raises — same gotcha `DpsComponent`'s evidence panel already comments on, missed
on the first pass here too and caught by the browser test.

Third-party identity/screening validation stays an open `ProviderAdapter`
callback with no implementation yet (`validate_field/2` returns
`{:error, :not_implemented}`) — deliberate, per the user's confirmed
architecture: keep it pluggable, add a real provider only when actually needed.

**Next: KYC-P4** — risk-scoring hook on approval (check CDM for an existing
engine first). **KYC-P5** — API layer.

### KYC-P3.5 — User feedback after seeing P1-P3 live: role split, step journey, UI ✅ Done 2026-07-29
Real feedback from the browser, not a planned phase — captured here as its
own entry rather than folded into P3's "done" line, since it changed shipped
behavior:

1. **Role separation** — "KYC Method created can be admin role whereas KYC
   request management is another user role, we should not keep at one
   place." Split the combined `KycComponent`/`kyc` module into two separate
   screens/permissions: `KycMethodsComponent` (`kyc_methods` — template
   design, SUPERVISOR edits, OPS/RISK/COMPLIANCE view-only, same pattern as
   `logo`/`block`) and `KycRequestsComponent` (`kyc_requests` — operational
   review, SUPERVISOR/OPS/RISK edit, COMPLIANCE view-only, same pattern as
   `wallet`/`debit`/`prepaid`). Two sidebar entries, not tabs in one screen.
2. **Step-based sequencing** — "I do not see Steps based KYC process
   option." Confirmed via `AskUserQuestion`: **sequential gate**, not just
   informational ordering. `Method` gained `step`/`required`; `Request`
   snapshots `step` at submission (same reasoning as `fields_snapshot`).
   New `VmuCore.Kyc.Journey.progress/2` classifies each of a product's
   methods as `:done`/`:current`/`:locked` for a customer (a method is
   locked until every earlier `required: true` step has an **approved**
   request); `submittable?/2` backs a defensive gate in `Requests.submit/2`
   (`{:error, :step_locked}`) — the submission UI shouldn't offer a locked
   step, but this isn't trusted from the caller either. The wizard's step-2
   screen now renders the ordered journey with Start/Locked/Resubmit
   instead of a flat method dropdown.
3. **UI polish** — reworked the Method editor from one long vertical form
   into a tabbed layout (Form Fields / Conditional Logic) closer to the MMS
   screenshot's shape. Deliberately **not** matching MMS's Third-Party-
   Validation/OCR-Configuration tabs — this build's OCR already runs
   automatically on every file upload with no per-field toggle needed, and
   third-party validation stays an unimplemented `ProviderAdapter` callback
   (§P3) with nothing to configure per-field yet.
4. **External API** — "we need to manage via API also some time." Not new
   scope; already KYC-P5, re-confirmed as real and not to be dropped.
5. **Risk engine pointer** — "the risk system mw-core/apps/mw_risk has LSEG
   implementation and it can be used." Confirmed real, already integrated:
   `VmuCore.CDM.SanctionsScreening.screen/1` is a direct (non-HTTP) call
   into `mw_risk`'s `MwRisk.SanctionsChecker`, fail-closed, with a measured
   real-latency budget against a real 76k-entry sanctions list. KYC-P4
   reuses this instead of building a new HTTP-based integration.

18/18 new tests (6 `Kyc.Journey` gating on real Postgres, 4 Methods-builder
browser tests including the tab switch and clone flow, 6 Requests browser
tests including the journey-locked-step assertion). Full suite 468 tests,
same 10 pre-existing failures, no regression.

### KYC-P4 — Risk-scoring hook on approval ✅ Done 2026-07-29
Reused `VmuCore.CDM.SanctionsScreening.screen/1` (per the user's own lead,
§P3.5 item 5) instead of building a new integration — `VmuCore.Kyc.
RiskScreening.screen_request/1` resolves the request's `Shared.Customer` and
screens `full_name`/`company_name`. Wired into `Kyc.Requests.approve/3`,
**before** the status change: a sanctions hit or an unavailable screen both
block approval outright (`{:error, {:sanctions_hit, hit}}` /
`{:error, :screening_unavailable}`) — fail-**closed**, same posture as the
underlying `CDM.SanctionsScreening`, and the same real gap the MMS reference
had (§ MMS_KYC_Feature_Reference.md item 10, "sanctions alerts are log-only")
now actually blocks the workflow instead of just logging.

Deliberately not a `Kyc.ProviderAdapter` implementation — that behaviour's
per-field shape doesn't fit a customer-level check.

**No override path yet** — a hit or unavailable screen leaves the request
exactly as it was, with no way for compliance to force an approval through.
A real gap, flagged for a later phase, not solved here.

Confirmed live before wiring in: `CDM.SanctionsScreening.screen/1` responds
in ~50ms against the test environment's `mw_risk` sanctions list (not the
1.3-1.6s measured against the real 76k-entry dev list — the test-env list is
much smaller), so this doesn't slow down approval meaningfully or break any
existing test. 3/3 new tests cover the `:clear` path and the missing-
customer `:error` case with real data; the `{:hit, _}` branch is real code
but not exercised by an automated test — this repo has no way to seed a
known sanctions match into `mw_risk`'s own database (a separate app/DB this
build doesn't own), an honest gap rather than a fabricated test. Full suite
471 tests, same 10 pre-existing failures, no regression.

### KYC-P5 — External API ✅ Done 2026-07-29
Confirmed in scope by the user ("The KYC process can be external and we need
to manage via API also some time"). Before building anything, checked what
API foundation already existed — **`docs/shared/NEW_PRODUCTS_PROGRAM_TRACKER.md`
claimed a whole `/api/v1/*` layer (`ServiceAccount`, `ErrorEnvelope`, rate
limiter, several controllers) was "✅ done"; none of that code exists in the
working tree**, only the `asm_service_accounts` migration (2026-07-12) was
real. Same "doc says done, code isn't there" pattern that's hit this program
repeatedly before (`project_platform_of_record_vmu_core`) — did not design
against that doc's claimed conventions; built from the real migrated schema.

- `ASM.ServiceAccount`/`ASM.ServiceAccounts` — bearer-token machine identity
  (`asm_service_accounts`, distinct from `ASM.Operator`'s human/password/
  session login). Token is SHA-256-hashed at rest, shown once at creation.
  Minimal ADMIN-only admin screen (`ServiceAccountsComponent`, same
  ADMIN-only-via-no-`RolePermission`-rows convention as `OperatorComponent`)
  to actually provision one — an API layer nobody can get a credential for
  isn't real.
- `VmuCoreWeb.Plugs.ApiV1Auth` — bearer-token auth + `require_scope/2`
  (`kyc:read`/`kyc:write`), piped through a new `:api_v1` router pipeline —
  a different trust boundary than the existing `:api` pipeline's internal
  shared-secret auth (FAS/`settlement_core`).
- `VmuCoreWeb.Api.V1.ErrorEnvelope` — consistent JSON error shape, `meta.
  request_id` sourced from `Plug.RequestId` (already in the endpoint
  pipeline, just unused for JSON responses until now).
- `VmuCoreWeb.Api.V1.KycController` — `GET /api/v1/kyc/methods`,
  `POST /api/v1/kyc/requests`, `GET /api/v1/kyc/requests/:id`,
  `POST /api/v1/kyc/requests/:id/documents` — thin wrappers over the
  existing `Kyc.Methods`/`Kyc.Requests`/`Kyc.Documents` contexts, no new
  business logic. No approve/reject endpoint — stays admin-console-only,
  matching every other approval flow in this program. Every mutation
  audited via `ASM.AuditLog.record/4` (actor `nil`, service account name
  in `details` — `AuditLog` is typed around a human `Operator`, not worth
  widening for one new caller kind).

17/17 new tests (5 `ServiceAccounts` context, 12 real-HTTP-pipeline
`KycController` tests covering auth/scope/happy-path/error cases for all
four endpoints, including a real multipart upload through to OCR). Full
suite 488 tests, same 10 pre-existing failures, no regression.

This closes KYC-P1 through P5 — the full plan from `docs/kyc/
KYC_Implementation_Tracker.md` §7 as originally scoped, plus the P3.5
mid-course correction from real user feedback.

### Post-P5 follow-up (2026-07-29) — UI layout + real seed data

More user feedback after seeing the Method editor live: "Why not keep the
layout similar to [MMS's real edit screen] — it gives better view and user
experience." Reworked `KycMethodsComponent`'s editor from one stacked column
into MMS's real shape — a fixed left column for method-level settings (name/
title/product/status/step/required) and a wide right column with the Form
Fields/Conditional Logic tabs, where each field is now its own bordered card
(label+key, type+required, options, an OCR hint on file fields) instead of a
cramped table row. Purely visual — the underlying field schema, event
handlers, and validation are unchanged; deliberately did not reintroduce
MMS's per-field Document-Type/OCR-toggle controls (§P3.5's reasoning still
holds: this build's OCR runs automatically on every upload, nothing to
configure per field).

Also seeded real demo data end-to-end (`priv/repo/seed_kyc_demo.exs`, `mix
run priv/repo/seed_kyc_demo.exs`, idempotent): Wallet accounts for 3 existing
demo customers (Wallet had zero seed data before this); a Fleet vehicle+card
for Zaabi Group LLC (CORPORATE_FLEET had zero real target accounts before
this — found a real FK on `hcs_fleet_cards.account_id` -> `cms_accounts`
that isn't visible from the Ecto schema alone, pointed at the company's own
`parent_account_id`, its central credit facility); one KYC Method per
product (CREDIT gets two, step 1+2, to exercise the journey feature), every
one with a *self-contained* conditional-logic pair (the source and target
fields must be on the same method/step — `Kyc.ConditionalLogic` evaluates
against one request's own `data`, so a rule can't span two different
requests/steps) and at least one `file` field; real KYC requests submitted
and approved/rejected/left-pending across all 7 products against real
customers.

**Real finding while seeding, not a bug**: three of the demo customers
(Ahmed Al Rashid on Wallet, Abdullah Al Zaabi and Mohammad Al Farsi on
Corporate Facility) triggered genuine fuzzy-match sanctions hits from the
real ~79.5k-entry OFAC-style list loaded in this dev environment
(`SanctionsCache: loaded 79509 entries from DB`) — KYC-P4's fail-closed gate
correctly blocked those approvals. Left them as `submitted` rather than
forcing them through; a demo that only ever shows green approvals wouldn't
prove the gate does anything. Confirms the `{:hit, _}` branch (previously
untested — §P4's own note that this repo can't seed a known match into
`mw_risk`'s database) is real and working, at least in an environment where
that database has real data loaded.
