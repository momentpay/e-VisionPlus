# CTA — Gap Implementation Tracker

> Source: `CTA_Module_Requirements.md` gap analysis. Phases `CTA-P1`..`CTA-P3`.
> Statuses: `✅ Done` · `🔄 In Progress` · `⬜ Pending`
> Last updated: 2026-07-05

---

## Headline gap (from the requirements review)

CTA has activation, PIN issuance, emboss-file, and stock modules — but **no
first-class card entity**. Card state rides on `cms_accounts` (`pan_token`,
`last_four`, `expiry_date`, `emboss_name`) + `cms_supplementary_cards` +
`cta_embossing_orders`. That model cannot represent **plastic generations**:
a replacement or renewal is a *new physical card* with its own PAN/expiry and
lifecycle, linked to but distinct from the prior one. Without it, FR-013
(card lifecycle), FR-016 (replacement), FR-017 (renewal), and FR-024 (card
event history) have nowhere to live.

## ADR-CTA1: Card entity is additive, account stays the hot-path cache

**Decision:** `cta_cards` becomes the system of record for the plastic
lifecycle. `cms_accounts.pan_token` / `last_four` / `expiry_date` /
`emboss_name` are **kept** as a denormalized cache of the account's *current
active card* — FAS's authorization hot path and `HotCardCache` keep reading
the account row unchanged (no hot-path disruption). CTA lifecycle operations
update both: the `cta_cards` generation history AND the account's current-card
denormals. A future phase can point FAS at `cta_cards` directly; until then
this is strictly additive (mirrors TRAM ADR-T2).

**Backfill:** every existing account gets one PRIMARY `cta_cards` row
(generation 1) derived from its current card denormals.

---

## CTA-P1 — First-Class Card Entity ✅ (2026-07-05)

| # | Task | File(s) | Status |
|---|------|---------|--------|
| P1.1 | Migration — `cta_cards` (card_id, account_id FK, pan_token unique-where-active, last_four, expiry MMYY, emboss_name, card_type PRIMARY/SUPPLEMENTARY/VIRTUAL, status 9-state, block_reason, generation, replaces_card_id, activation_method, channel-control flags nullable, issued/activated/blocked/expired timestamps, dispatch_ref) | migration `20260705000001` | ✅ |
| P1.2 | `Card` schema + changeset (type/status/block-reason inclusion, pan_token active-uniqueness) | `cta/card.ex` | ✅ |
| P1.3 | `CardStateMachine` — 9-state lifecycle (ORDERED→EMBOSSED→DISPATCHED→INACTIVE→ACTIVE→BLOCKED⟲, →EXPIRED, →REPLACED, →DESTROYED); pure module | `cta/card_state_machine.ex` | ✅ |
| P1.4 | `Cards` context — issue/get/by_account/by_pan_token/current_card, `transition/3` (validates + stamps timestamps + syncs account denormals for the active card) | `cta/cards.ex` | ✅ |
| P1.5 | Backfill script — one PRIMARY gen-1 card per account from current denormals (idempotent) | `priv/repo/backfill_cta_cards.exs` | ✅ |

**Verification (2026-07-05):** migrated + backfilled 10/10 accounts; smoke-tested
9/9 — backfill coverage matches account count; `current_card/1` resolves with
denormals matching the account; state-machine validation (INACTIVE→ACTIVE ok,
ACTIVE→DISPATCHED and EXPIRED→ACTIVE rejected); issue→activate stamps
`activated_at` + method; block-with-reason→unblock round-trip; invalid
transition rejected; active-PAN uniqueness blocks a second live card on the
same PAN; replacement pattern (retire gen-1 REPLACED → reissue gen-2 same PAN
with `replaces_card_id`) works because the terminal state frees the partial
unique index.

---

## CTA-P2 — Lifecycle Operations ✅ (2026-07-05)

All ops in `VmuCore.CTA.CardLifecycle`; expiry/renewal in a nightly Oban sweep.

| # | Task | File(s) | Status |
|---|------|---------|--------|
| P2.1 | `activate/2` — INACTIVE→ACTIVE via `Cards.transition` (stamps method + syncs account denormals), audited | `cta/card_lifecycle.ex` | ✅ |
| P2.2 | `block/3` + `unblock/2` — card→BLOCKED with reason; LOST/STOLEN/FRAUD also set the account `block_code` (L/S/F) and `HotCardCache.refresh/0` so auth declines; unblock clears both | `cta/card_lifecycle.ex` | ✅ |
| P2.3 | `replace/3` — old→REPLACED + new generation (`replaces_card_id`, gen+1); LOST/STOLEN/FRAUD require caller-supplied `new_pan_token` (compromised PAN changes), DAMAGED keeps the PAN; account re-pointed to the new plastic (+ block cleared for new-PAN reasons); replacement fee via `FeeEngine.assess_card_replacement_fee` (waivable, skipped for FRAUD) | `cta/card_lifecycle.ex` | ✅ |
| P2.4 | `renew/2` (same PAN, bumped expiry `:cta_renewal_years`, new gen) + `CardExpirySweepJob` (cron 04:00): auto-renews ACTIVE PRIMARY cards within `:cta_renewal_lead_days` (default 30) unless account CLOSED/WRITTEN_OFF/dormant; expires any live card past its MMYY month → EXPIRED. MMYY helpers (`expiry_end_date`/`expired?`/`bump_expiry`) in `Cards` | `cta/card_lifecycle.ex` · `cta/oban/card_expiry_sweep_job.ex` · `cta/cards.ex` · `config/config.exs` | ✅ |

**Verification (2026-07-05):** smoke-tested 9/9 against `vmu_core_dev` —
activate syncs account PAN; block LOST sets `block_code: "L"` + hot cache
`{:blocked, :lost_stolen}`; unblock clears both; replace-LOST demands a new PAN
(guard), issues gen-2 with changed PAN and re-points the account; DAMAGED keeps
the PAN; FRAUD skips the fee; renew keeps the PAN and bumps 1228→1231; expiry
helpers correct; sweep expired a past-dated card. Originals restored.

## CTA-P3 — Admin UI & Card-Level Controls ✅ (2026-07-07)

| # | Task | File(s) | Status |
|---|---|---|---|
| P3.1 | Card list + lifecycle actions folded into the existing account "Cards" tab (rather than a new sidebar page — matches the tracker's own "list per account" scope and the staff workflow of servicing a customer from their account screen). Replaced the static denormal snapshot with the real `cta_cards` generation table (gen, type, masked PAN, status badge, channel-control dots, issued date) + per-row action buttons (Activate/Block/Unblock/Replace/Renew/Channels) gated by card status, each opening an action panel in the existing `active_action` idiom | `live/admin/account_component.ex` (`tab_cards/1` rewrite + 6 new `render_action_panel` clauses + 8 new `handle_event` clauses) | ✅ |
| P3.2 | Card-level channel-control overrides — tri-state (`true` force-allow / `false` force-block / `nil` inherit) on `ecom_enabled`/`atm_enabled`/`contactless_enabled`/`intl_enabled`, editable via the new "Channels" action panel; `Cards.set_channel_controls/2` + `CardLifecycle.set_channel_controls/3` (audited); wired into **`FAS.CardValidator.validate_channel_flags/4`** ahead of the LOGO parameter cascade — the card lookup is one indexed `pan_token` seek, same cost class as the existing `resolve_account/1` call later in the same pipeline | `cta/cards.ex` · `cta/card_lifecycle.ex` · `fas/card_validator.ex` | ✅ |
| P3.3 | Card event history — `ASM.AuditLog.for_subjects/2` (new: multi-subject query, `search/2`'s single-subject filter can't aggregate several card generations' events on one screen) powers a timeline of every `card_*` audit action across all of an account's card generations, newest first, reusing the existing `.timeline` CSS | `asm/audit_log.ex` · `live/admin/account_component.ex` | ✅ |

**Verification (2026-07-07):**
- P3.2 backend, 8/8 checks — no-override falls through to the LOGO cascade; card `false` force-blocks a channel the logo allows; unrelated channel unaffected; card `true` force-allows a channel the logo blocks; reset-to-`nil` restores cascade-only behavior; 3 audit entries recorded across the false/true/nil sequence; `intl_enabled: true` force-allows a foreign-currency transaction; unknown PAN fails open (pre-P3 behavior preserved).
- P3.1/P3.3 data layer, 6/6 checks — a full lifecycle chain (issue → activate → block DAMAGED → replace → activate gen2 → renew gen3 → set channel controls) produced the correct newest-first generation order `[3,2,1]`, correct terminal statuses (`REPLACED`, `REPLACED`, `ACTIVE`), correct tri-state channel values, a complete 6-action timeline aggregated across all three card IDs in chronological order, and the account denormals correctly synced to gen3's renewed expiry.
- Compiles clean (`mix compile --force`), no new warnings.

**Bug found during P3.2 verification (pre-existing, NOT introduced by CTA-P3) — ✅ fixed 2026-07-07:**
`FAS.CardValidator.check_intl/3`'s international check compared DE49 (ISO 4217
**numeric**, e.g. `"784"`) directly against `base_currency` (stored **alpha**,
e.g. `"AED"`), declining every domestic transaction using a numeric currency
code whenever `intl_enabled` was false. Fixed via a new
`Shared.CurrencyCodes.same_currency?/2` (normalizes both sides before
comparing; fails safe to raw-string comparison for any code outside its
table — no behavior change for currencies it doesn't cover). Also
consolidated a duplicate, narrower 4-entry version of the same bug found in
`TRAMS.MastercardIpm.iso4217_numeric_to_alpha/1` into the same shared
module. Verified: domestic 784-vs-AED now `:ok` (previously declined);
genuine foreign 840-vs-AED still correctly declines per `intl_enabled`; 8/8
checks. See `lib/vmu_core/shared/currency_codes.ex`.

---

## CTA-P4 — Module Configuration (Emboss/Replacement/Renewal/Wallet/PIN) ✅ (2026-07-08)

Resolves the 5 open questions in `CTA_Module_Requirements.md` §6 — each answer was
"it varies by customer/deployment, make it configurable," so this phase implements a
shared, reusable configuration framework rather than one-off settings. Full design and
verification: `docs/shared/Module_Configuration_Framework.md`.

| # | Task | File(s) | Status |
|---|---|---|---|
| P4.1 | Generic Module Configuration framework: `shared_module_configs` table, `ModuleConfigEntry` schema, `ModuleConfigCatalog` registry, `ModuleConfigEngine` (ETS cascade reader), `ModuleConfigWriter` (validated writer + audit) | `priv/repo/migrations/20260708000000_create_shared_module_configs.exs`, `lib/vmu_core/shared/module_config_{entry,catalog,engine,writer}.ex` | ✅ |
| P4.2 | CTA config catalog — 8 keys: emboss template/delivery/encryption, replacement PAN policy, renewal lead time + dormancy, wallet tokenization mode, PIN-set channels (incl. ATM) | `lib/vmu_core/cta/config_catalog.ex` | ✅ |
| P4.3 | Generic admin UI — catalog-driven Module Configuration screen (System/Bank/Logo scope picker, module tabs) | `lib/vmu_core_web/live/admin/module_config_component.ex`, `admin_live.ex` wiring | ✅ |

**Verification (2026-07-08):** `mix compile --warnings-as-errors` clean. Smoke test
covering default fallback, scope cascade, invalid-enum/unknown-key rejection, and
audit trail — all passed (see `docs/shared/Module_Configuration_Framework.md` §7).
Admin UI loaded as ADMIN with no server errors.

## CTA-P4.4 — Wire config keys into real business logic ✅ (2026-07-08, same day)

P4.2 only registered the 8 catalog keys — none were actually consumed by CTA business
logic yet (config existed, editable, but zero behavioral effect). Investigated each
key's real hardcoded equivalent before wiring (see
`docs/shared/Module_Configuration_Framework.md` §8 for the "configurable ≠ wired"
principle this phase follows).

| # | Task | File(s) | Status |
|---|---|---|---|
| P4.4.1 | `card_replacement_pan_policy` — replaces the hardcoded `@new_pan_reasons` list in `resolve_replacement_pan/3`; `HotCardCache.refresh()`/account-block-clear now driven by whether the PAN actually changed (per the resolved policy), not a static reason list. Caught catalog default gap: FRAUD was missing from the default map (would have silently fallen back to "same") — added `"FRAUD" => "new"` to match prior behavior. | `lib/vmu_core/cta/card_lifecycle.ex`, `lib/vmu_core/cta/config_catalog.ex` | ✅ |
| P4.4.2 | `renewal_lead_time_days` + `renewal_dormancy_suppression` — replaces the single global `Application.get_env(:cta_renewal_lead_days, 30)` and the always-on `is_nil(a.dormant_since)` filter; both now resolved **per candidate** (per bank/logo) since one sweep batch spans many logos | `lib/vmu_core/cta/oban/card_expiry_sweep_job.ex` | ✅ |
| P4.4.3 | `emboss_file_template` — v1 scope: field-width/value overrides (pan/expiry/name/service_code/sequence/cvc2/track2/logo_id widths + record_length) merged over the built-in 128-char layout, resolved per order (per bank/logo). Not a full upload-and-map wizard (see Module_Configuration_Framework.md §6). | `lib/vmu_core/cta/embossing_file_generator.ex` | ✅ |
| P4.4.4 | `pin_set_channels_enabled` — **not wired**. Investigation found `IvrSession.change_pin/3` has no matching `handle_call` clause at all (dead public API — a pre-existing gap, not something this phase introduced) and `PinIssuance.change_pin/3` is never called from anywhere in the codebase. There is no working PIN-change path for any channel to gate. Moved to the deferred/no-consumer list alongside `emboss_delivery_channel`/`emboss_encryption_method`/`wallet_tokenization_mode`. | — | ⬜ deferred |
| P4.4.5 | **Bug found + fixed during verification:** `EmbossingFileGenerator.pending_orders/0` selected a nonexistent `o.id` column (actual PK is `order_id`) — would have crashed with a Postgres "column does not exist" error on any real embossing run. Never previously exercised end-to-end. | `lib/vmu_core/cta/embossing_file_generator.ex` | ✅ |

**Verification (2026-07-08):** live end-to-end tests against real accounts/cards (full
app boot): (1) default LOST replacement issues a new PAN; after overriding the
logo's policy to `LOST => "same"`, a second LOST replacement correctly kept the same
PAN with no `new_pan_token` required; (2) default emboss record is 128 chars; after
overriding `pan_width`/`name_width` at logo scope, the generated record showed the
narrower fields with total length still 128 (verified actual record content, not just
length). Reverted all test overrides after.

**Deferred (config-only, no consumer today, not actioned):** `emboss_delivery_channel`
(no real file delivery exists — `BureauAdapter.submit_embossing_file/1` is a stub),
`emboss_encryption_method` (no encryption exists anywhere), `wallet_tokenization_mode`
(no wallet/tokenization code exists anywhere), `pin_set_channels_enabled` (dead IVR
PIN-change handler, see P4.4.4). Wiring these means building real subsystems
(SFTP/email delivery, PGP encryption, wallet token integration, a working IVR/app/web/
atm PIN-change flow), not rewiring an existing hardcode — explicitly out of scope for
this phase, by user decision.

## Overall

| Phase | Items | Done |
|-------|-------|------|
| CTA-P1 Card Entity | 5 | 5 |
| CTA-P2 Lifecycle | 4 | 4 |
| CTA-P3 UI & Controls | 3 | 3 |
| CTA-P4 Module Configuration | 3 | 3 |
| CTA-P4.4 Config Wiring (4/5 wireable; 4 deferred, no consumer) | 5 | 4 |
| **TOTAL** | **20** | **19** |

**CTA gap plan + module configuration complete as of 2026-07-08.** The one open item
(P4.4.4, `pin_set_channels_enabled`) is deliberately deferred, not incomplete work —
it requires building a working PIN-change flow first, which doesn't exist for any
channel today.

**CTA gap plan + module configuration complete (15/15) as of 2026-07-08.**
