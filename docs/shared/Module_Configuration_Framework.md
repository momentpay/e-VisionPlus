# Module Configuration Framework

**Status:** ✅ Implemented (2026-07-08). Complementary to `VmuCore.Shared.ParameterEngine`
(the SYS→BANK→LOGO→BLOCK hot-path pricing/limits cascade) — this framework is the
answer to "make it configurable" wherever an open question in a module's requirements
doc turned out to be a deployment-specific choice, not a fixed business rule.

---

## 1. Why this exists

`docs/cta/CTA_Module_Requirements.md`, `docs/asm/ASM_Module_Requirements.md`, and
`docs/dps/DPS_Module_Requirements.md` each shipped with open questions. When those
questions were answered, they turned out to share one shape — every answer was some
version of *"it varies by customer/market/deployment, so make it configurable"*:

- **CTA** — emboss file record layout (vendor template upload), delivery channel
  (email/sftp), encryption method (PGP to start), new-PAN-on-replacement policy per
  reason code, renewal lead time + dormancy suppression, wallet tokenization mode,
  PIN-set channels (explicitly including ATM).
- **ASM** — authentication source (SSO/AD/LDAP/local, a bank IT constraint), PII
  masking rules (role-wise), audit retention period (default 7yr).
- **DPS** — network connectivity mode (manual portal *and* API integration must
  coexist), provisional credit window (per customer/market), evidence storage backend
  (DB by default, S3/Azure as options).

Hand-wiring each of these as one-off settings would mean every future module (COL,
MBS, ITS, HCS, CDM, ...) reinvents the same problem. This framework generalizes the
pattern once, so a new module's "make it configurable" answers become a data file, not
new plumbing.

## 2. Relationship to `ParameterEngine` — two stores, two jobs

| | `ParameterEngine` | Module Configuration Framework |
|---|---|---|
| Purpose | Pricing/limits feeding real-time authorization | Operational/integration/policy settings for every other module concern |
| Shape | Fixed Ecto columns per level (`sys_parameters`, `bank_parameters`, ...) | Generic EAV: `(scope, module, config_key) → JSON value` |
| Adding a setting | Requires a migration + explicit `ParameterEngine` loader code | Requires only a new catalog entry — no migration, no loader change |
| Hot path? | Yes — sub-50ms authorization SLA, ETS-only reads | No — read during embossing, PIN issuance, dispute case actions, login, etc. |
| Value types | Scalars (decimal/string/boolean/integer) + a few `:map` fields | Any JSON: scalar, list, or structured map (e.g. an uploaded field-mapping template) |

**Rule of thumb:** if a value feeds the FAS authorization decision path, it belongs in
`ParameterEngine`. Everything else — anything a module reads when doing its own
business logic, not on the switch's hot path — belongs here.

## 3. Architecture

### Schema — `shared_module_configs`

One row per `(scope_type, sys_id, bank_id, logo_id, module, config_key)`. `bank_id`/
`logo_id` use `""` (not `nil`) as the "not applicable at this scope" sentinel so the
composite unique index behaves predictably under Postgres NULL semantics. `value` is
stored as `%{"v" => <config value>}` — Ecto's `:map` type only casts actual maps, so
scalars/lists are wrapped in a one-key envelope (handled transparently by the
reader/writer below; never accessed directly).

Schema module: `VmuCore.Shared.ModuleConfigEntry`
(`lib/vmu_core/shared/module_config_entry.ex`).

### Catalog — `VmuCore.Shared.ModuleConfigCatalog`

Every config key that exists is declared in a catalog spec:

```elixir
%{
  key: "renewal_lead_time_days", module: "cta", type: :integer,
  allowed: nil, default: 30, scope: :logo,
  description: "Days before expiry that auto-renewal reissue is triggered."
}
```

`type` drives both validation (`ModuleConfigCatalog.validate/3`) and the admin UI's
input widget: `:string`, `:boolean`, `:integer`, `:enum` (+ `allowed` list),
`:list` (+ optional `allowed` list, rendered as checkboxes), `:map` (rendered as a
JSON textarea).

Each module owns its own catalog file — this is the extension point:

- `lib/vmu_core/cta/config_catalog.ex` — 8 keys
- `lib/vmu_core/asm/config_catalog.ex` — 4 keys
- `lib/vmu_core/dps/config_catalog.ex` — 4 keys

`ModuleConfigCatalog.all/0` concatenates them; `for_module/1` and `fetch/2` filter.

### Engine (reader) — `VmuCore.Shared.ModuleConfigEngine`

GenServer + ETS table `:vmu_module_config_cache`, mirroring `ParameterEngine`'s
cache-and-cascade shape. `get(module, key, sys_id, bank_id \\ "", logo_id \\ "")`
cascades **logo → bank → system** DB rows, falling back to the catalog's `default`
when no row exists at any level. `{:error, :unknown_key}` only means the key was never
registered in any catalog — an unset-but-known key always resolves via its default,
so callers never need a special "not configured yet" branch.

Started in the supervision tree (`lib/vmu_core/application.ex`) immediately after
`ParameterEngine`.

### Writer — `VmuCore.Shared.ModuleConfigWriter`

`put(module, key, value, scope, operator)`:
1. Validates `value` against the catalog spec (`ModuleConfigCatalog.validate/3`).
2. Upserts the row (`ON CONFLICT` on the scope+module+key unique index).
3. Refreshes `ModuleConfigEngine`'s ETS cache in the same call — refresh is
   guaranteed, not caller-remembered (same contract `ParameterWriter` gives
   `ParameterEngine`).
4. Writes an audit entry via the existing `VmuCore.ASM.AuditLog.record/4` sink
   (`cms_operator_audit` table) — action `"config_update"`, subject `"<module>.<key>"`,
   details include old/new value and scope. No new audit table needed.

### Admin UI — one generic screen

`VmuCoreWeb.Live.Admin.ModuleConfigComponent`
(`lib/vmu_core_web/live/admin/module_config_component.ex`), wired into the admin
console at **Module Configuration** (sidebar, under Parameter Hierarchy). Renders
whichever catalog is selected (CTA/ASM/DPS today) with a scope picker (System / Bank /
Logo, with Bank/Logo dropdowns sourced from the existing `BankParameter`/
`LogoParameter` tables) and a type-appropriate input per key. Adding a new module's
catalog automatically gets a working admin screen — no new LiveView code required.

**v1 permission gate:** editing requires `Authz.can?(operator, "system", "edit")` —
the same coarse ADMIN-only gate as the System Parameters screen (viewing follows the
same "system" visibility as that screen). This is intentionally coarse to start;
per-target-module permission rows (e.g. a `"cta"` row in `RolePermission`) are a
natural follow-up, not built here — see §5.

## 4. Current catalog reference

### CTA (`lib/vmu_core/cta/config_catalog.ex`)

| Key | Type | Scope | Default | Answers | Wired? |
|---|---|---|---|---|---|
| `emboss_file_template` | map | logo | `{}` | Vendor field-mapping template (record layout) | ✅ `embossing_file_generator.ex` (field-width overrides, v1) |
| `emboss_delivery_channel` | enum `[email, sftp]` | logo | `sftp` | Delivery channel | ⬜ no delivery path exists |
| `emboss_encryption_method` | enum `[pgp]` | bank | `pgp` | Encryption | ⬜ no encryption exists |
| `card_replacement_pan_policy` | map | logo | `{LOST: new, STOLEN: new, FRAUD: new, DAMAGED: same}` | New-PAN-on-replacement policy | ✅ `card_lifecycle.ex` |
| `renewal_lead_time_days` | integer | logo | `30` | Renewal lead time | ✅ `card_expiry_sweep_job.ex` |
| `renewal_dormancy_suppression` | boolean | logo | `true` | Dormancy suppression rule | ✅ `card_expiry_sweep_job.ex` |
| `wallet_tokenization_mode` | enum `[disabled, scheme_token, own_token]` | logo | `disabled` | Wallet tokenization scope | ⬜ no wallet/tokenization code exists |
| `pin_set_channels_enabled` | list `[ivr, app, web, atm]` | bank | `[ivr, app]` | PIN set channels | ✅ "ivr" only — `VmuCore.IVR.IvrSession` (`app`/`web`/`atm` have no endpoint) |

See `docs/cta/CTA_Gap_Implementation_Tracker.md` CTA-P4.4 for the wiring detail and why
the three remaining ⬜ rows have nothing to wire into yet.

### ASM (`lib/vmu_core/asm/config_catalog.ex`)

| Key | Type | Scope | Default | Answers | Wired? |
|---|---|---|---|---|---|
| `authn_source` | list `[local, sso, ad, ldap]` | bank | `[local]` | AuthN source | ⬜ real SSO/AD/LDAP integration, out of scope |
| `authn_provider_config` | map | bank | `{}` | Provider connection settings | ⬜ same as above |
| `pii_masking_rules` | map | system | `{}` | PII masking, role-wise | ✅ `customer_component.ex` (id_number, date_of_birth) |
| `audit_retention_days` | integer | system | `2555` (7yr) | Audit retention | ✅ new `audit_retention_sweep_job.ex` |

*Not covered:* the role-taxonomy question is a design task, not a config key — see §5.
See `docs/asm/ASM_Implementation_Tracker.md` ASM-P6.3 for the wiring detail.

### DPS (`lib/vmu_core/dps/config_catalog.ex`)

| Key | Type | Scope | Default | Answers |
|---|---|---|---|---|
| `network_connectivity_mode` | map | bank | `{VISA: manual, MASTERCARD: manual}` | Manual vs API per network |
| `provisional_credit_window_days` | integer | bank | `10` | Provisional credit window |
| `evidence_storage_backend` | enum `[db, s3, azure_blob]` | bank | `db` | Evidence storage |
| `evidence_storage_config` | map | bank | `{}` | Backend connection settings (bucket/container; never a raw secret) |

*Not covered:* completing the arbitration flow is feature/state-machine work, not a
config key — see §5.

## 5. How a new module adds configuration

1. Create `lib/vmu_core/<module>/config_catalog.ex` exposing `entries/0` — a list of
   specs shaped like the ones above.
2. Register it in `VmuCore.Shared.ModuleConfigCatalog.all/0`.
3. Done. `ModuleConfigComponent` renders it automatically; `ModuleConfigEngine.get/5`
   and `ModuleConfigWriter.put/5` work immediately.

No migration. No new admin UI code. This is what future module planning (COL, MBS,
ITS, HCS, CDM) should follow whenever a requirements doc's open question turns out to
be "it varies by customer/market" rather than a fixed business decision.

## 6. Out of scope (flagged, not actioned)

- **ASM role taxonomy** (3 org-size examples: Large/Medium/Small bank) — a genuine
  design task, not a config key. Candidate for a follow-up conversation.
- **DPS arbitration flow completion** — state-machine/GL feature work, unrelated to
  configuration.
- **Per-module RBAC rows** (e.g. `"cta"`/`"dps"` entries in `RolePermission`) for
  fine-grained module-config edit permission — v1 uses the coarser `system:edit` gate.
- **`emboss_file_template` upload/mapping wizard UX** — this framework stores the
  *result* of a vendor field-mapping exercise as a `:map` value; the upload +
  column-mapping wizard itself is separate UI work, not part of this framework.

## 7. Verification performed

- `mix compile --warnings-as-errors` — clean (no warnings from any new file).
- Smoke test (`ModuleConfigEngine`/`ModuleConfigWriter`, `iex -S mix` style): unset
  key falls back to catalog default; write at logo scope is picked up by the cascade;
  a different logo with no override still resolves to the default; a system-scope
  write cascades correctly; an invalid enum value is rejected with
  `{:error, :invalid_value}`; an unknown key is rejected with `{:error, :unknown_key}`;
  a successful write produces a `config_update` row in `cms_operator_audit` with the
  old and new values.
- Admin UI: loaded `/visionplus/admin/module_config` as ADMIN — page renders the CTA
  catalog by default with module tabs (CTA/ASM/DPS), a scope selector (System/Bank/
  Logo with Bank/Logo pickers), and all catalog keys with descriptions; no server
  errors in the log.

## 8. A note on "configurable" vs "wired"

Registering a catalog entry makes a setting **storable and editable** — it does not by
itself make any module's business logic **behave differently**. Each consuming module
still has to be updated to actually call `ModuleConfigEngine.get/5` at the point that
mattered, instead of its old hardcoded constant.

`dps.provisional_credit_window_days` is the reference example this framework got
wrong once and then corrected (`docs/dps/DPS_Gap_Implementation_Tracker.md` DPS-P1.3):
the first wiring attempt plugged the *provisional credit* window into the *dispute-
filing eligibility* check (`TRAMS.DisputeBridge.check_dispute_window/1`, FR-DPS-003 —
a distinct 120-day concept) by mistake. It was caught before shipping, reverted, and
correctly wired into `VmuCore.DPS.Dispute`'s new `provisional_credit_deadline` field
instead — verified against a real account with both the default and a bank-scope
override. `dps.network_connectivity_mode` and `dps.evidence_storage_backend` are, as
of 2026-07-08, still config-only — there is no VROL/Mastercom integration or evidence
storage abstraction for them to drive yet. **When adding a new catalog entry, budget a
separate step to actually wire it into the consuming module's logic, and verify with a
real read/write against real data — not just that the value round-trips through the
store.**

**Follow-up pass (2026-07-08, same day):** went through every registered CTA/ASM key
and wired each one that had a real hardcoded equivalent to replace —
`card_replacement_pan_policy`, `renewal_lead_time_days`,
`renewal_dormancy_suppression`, `emboss_file_template` (CTA), and `pii_masking_rules`
+ `audit_retention_days` (ASM, the latter via a brand-new Oban job since no purge
capability existed at all). Investigated the other 6 keys first rather than assuming:
`emboss_delivery_channel`, `emboss_encryption_method`, `wallet_tokenization_mode`,
`pin_set_channels_enabled` (CTA), and `authn_source`/`authn_provider_config` (ASM) all
turned out to have **zero working consumer** — no file delivery path, no encryption,
no wallet integration, a dead IVR PIN-change handler, and no SSO/AD/LDAP integration,
respectively. Building any of those means building a real subsystem, not rewiring a
hardcode, and was left deliberately deferred (by explicit user decision) rather than
stubbed out to look more complete than it is. Every wiring above was verified against
real data (real cards, real accounts, a live admin-console login as a non-ADMIN
operator for the masking check) — see `CTA_Gap_Implementation_Tracker.md` CTA-P4.4 and
`ASM_Implementation_Tracker.md` ASM-P6.3 for the exact verification steps. This pass
also caught a second latent bug purely by trying to exercise the code for real:
`EmbossingFileGenerator.pending_orders/0` selected a nonexistent `o.id` column (the
real PK is `order_id`) — would have crashed on any actual embossing run.

**`pin_set_channels_enabled` follow-up, same day:** initially listed as deferred
(no working consumer), but investigating *why* revealed `IvrSession.change_pin/3` was
a dead public API (no matching `handle_call` clause) aliasing `CTA.PinIssuance` — a
disconnected duplicate PIN system, never wired to anything, using a different PIN-block
encoding than the real one `FAS.Authorization` actually verifies against
(`FAS.HSM.verify_pin/3` → `CMS.CardPin`'s PBKDF2 hash). Wiring the dead stub would have
"fixed" the crash without affecting real PIN verification at all — worse than doing
nothing, since it would look complete without being real. Instead extended the real
system: `HSM.change_pin/3` takes plaintext PIN digits (self-service channels never
have the raw PAN needed to decode an ISO 9564 block) and reuses `verify_pin`'s exact
lockout logic against `CMS.CardPin`. This is the pattern to follow whenever a
"deferred, no consumer" key's investigation surfaces a *disconnected* stub rather than
*no* code at all: prefer extending the real system over wiring the dead one, even
though it's more work.
