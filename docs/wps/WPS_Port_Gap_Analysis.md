# WPS — gap analysis of `wallet_wps` against vmu_core

| Property | Value |
|---|---|
| Date | 2026-08-06 |
| Purpose | What exists in wallet-app, what is worth porting, and what must be built |
| Trigger | **VMU-ADR-004 retires wallet-app.** Everything below is deleted with it |
| Supersedes | The "do not rebuild this in vmu_core" recommendation in `WPS_Module_Requirements.md` |

---

## 1. Why this is time-sensitive

`WPS_Module_Requirements.md` (2026-07-11) recommends treating `wallet_wps` as
the starting point and *not* rebuilding in vmu_core. That recommendation is
**stale**: [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md),
accepted 2026-08-01, retires wallet-app entirely, and
[VMU-ADR-001](../decisions/001-platform-of-record.md) makes standalone
`vmu_core` the platform of record.

`wallet_wps` is also **not a dependency** — it has never appeared in
`vmu_core/mix.exs`. It is unreferenced code in a repository scheduled for
removal, which is precisely the shape of the merge-drift that has cost this
project real work ten times over.

**If wallet-app is deleted before this is extracted, roughly 6,400 lines go with
it.**

---

## 2. What actually exists

Measured 2026-08-06, across three apps:

| Where | What | Lines |
|---|---|---|
| `apps/wallet_wps/lib` | Domain, stores, commands, parser | 4,261 |
| `apps/wallet_wps/test` | Two real pipeline tests | 647 |
| `apps/wallet_web/.../admin/wps` | **4 LiveView screens** — files, employers, exceptions, approvals | 1,504 |
| `apps/wallet_database/schemas/wps` | 6 Ecto schemas | — |
| `apps/wallet_database/priv/repo/migrations` | 5 migrations: files, salary credits, exceptions, beneficiary links, refund requests, employers | — |

This is not a scaffold. The pipeline is real and coherent:

```
ingest(attrs, raw_bytes)          parse + persist the file
  → pre_flight_report(file_id)    what would post, what would fail, before committing
  → post_batch(file_id)           per-line disbursement
  → rerun_batch(file_id)          idempotent on payment_reference
  → retry_exception(id, actor)    remediation, not silent drops
  → link_beneficiary(...)         employee_id → account
```

`SalaryCredit` carries a real status lifecycle
(`parsed → validated → pending → posted → failed → settled`) with guarded
transitions, and there is an **employer refund maker-checker** that the
requirements doc does not even list as a feature — deliberately scoped so only a
`:posted` (not yet `:settled`) credit is refundable, because worker clawback is
a different problem.

---

## 3. ⚠️ The parser is not a WPS parser

**This is the finding that matters most, and it inverts the value of the
largest single module.**

`wps_parser.ex` is 505 lines and the centrepiece of the app. It is a **generic
salary-file parser**, not an implementation of any WPS scheme's file format:

| Evidence | |
|---|---|
| Acronym | Documented as *"Worker Payment System"*. WPS is the **Wage Protection System** |
| Default currency | `"USD"`. No GCC scheme uses USD — UAE is AED, Saudi SAR, Bahrain BHD |
| Record types | No `EDR` (Employee Detail Record) or `SCR` (Salary Control Record) anywhere |
| Regulator concepts | No MOHRE, no employer unique id, no bank/agent routing codes |
| Fixed-width layout | An invented `@fixed_width_fields` table, not a published column map |
| Date format | `YYYY-MM-DD`; the real SIF uses positional `YYYYMMDD` |
| Excel | A stub |

So the one part of a **regulatory** ingestion module that most needs a real
specification is the one part that was guessed. `WPS_Module_Requirements.md` §4
raised exactly this caution — *"don't guess a file format, get the real spec"* —
and the existing code did not honour it.

**Consequence for planning:** the parser is worth porting as a *shape* (multi-format
dispatch, error accumulation rather than fail-fast, per-line error records with
line numbers), and worth **nothing** as a compliance artefact. Its field layer
must be rewritten against a real spec before any pilot.

---

## 4. Coupling — small, and mostly mechanical

`wallet_wps` touches only four external namespaces:

| Dependency | Uses | Replacement in vmu_core |
|---|---|---|
| `WalletSharedKernel.TypedId` | 6 | `Ecto.UUID` |
| `WalletEvents.DomainEvent` | 6 | vmu_core's own event pattern |
| `WalletObservability.AuditEvent` | 5 | `VmuCore.ASM.AuditLog` |
| `WalletSharedKernel.Money` | 2 | `Decimal` (mandatory per `CLAUDE.md`) |
| `WalletDatabase.WriteThrough.*Persistence` | 6 | plain Ecto contexts |

The ledger seam is already clean: `PostSalaryCredit.execute/3` takes injected
`beneficiary_resolver` and `ledger_poster` functions rather than calling a ledger
directly. Porting means supplying a poster that calls `CMS.InternalGlPoster` —
which, post-C3, routes to `Posting.RuleEngine`.

### The architectural mismatch

`wallet_wps` keeps six **ETS + GenServer stores** with write-through persistence.
vmu_core uses plain Ecto contexts. The ETS layer buys nothing for batch file
processing — the access pattern is bulk load, bulk post, occasional query — and
carries real cost: process supervision, index tables to keep consistent, and
state that does not survive a restart.

**Port the schemas and the domain logic; drop the stores.**

---

## 5. What vmu_core already provides

Both prerequisites `WPS_Module_Requirements.md` called hard blockers are now
satisfied, which they were not in July:

| Requirement | Status |
|---|---|
| **Phase W1** — "WPS cannot start until Prepaid or Debit has its ledger/balance model built" | **Met.** Both are first-class GL products, cut over, with posting rules and real accounts |
| Employer → many worker cards, funded centrally | **Met, and stronger than the doc assumed.** HCS is now GL-integrated with its own receivables (`1006`/`1009`/`2002`) — a proven template, not just a shape to copy |
| Per-line disbursement | `Posting.RuleEngine` + `InternalGlPoster` |
| Exception remediation | DPS and the GL exception queue are both precedents |
| Bulk file pipeline | Broadway is already a dependency (TRAMS clearing) |

---

## 6. Recommended disposition

| Component | Disposition |
|---|---|
| Ingestion pipeline shape (`ingest` → `pre_flight_report` → `post_batch` → `rerun_batch` → `retry_exception`) | **Port.** This is the real design value |
| `SalaryCredit` status lifecycle + guarded transitions | **Port** |
| Exception classification and queue | **Port** |
| Employer refund maker-checker | **Port.** A real requirement the spec doc missed |
| 6 Ecto schemas + 5 migrations | **Port**, adapted to vmu_core naming |
| 4 LiveView admin screens | **Port**, reskinned to the admin menu standard |
| `wps_parser.ex` — structure | **Port** |
| `wps_parser.ex` — field layout | **Rewrite against a real spec.** Blocking for go-live, not for build |
| 6 ETS/GenServer stores | **Discard.** Replace with Ecto contexts |
| `TypedId`, `Money`, `DomainEvent`, `AuditEvent` | **Discard.** Map to vmu_core equivalents |

### As its own GL product

Following the six-concern template HCS established (see
`../gl/Phase_C2_Reader_Migration.md` §6b), WPS should get its own product
label(s) so salary-disbursement liability is separable from ordinary prepaid
float. Whether that is one `WPS` label or split by underlying instrument depends
on the Prepaid-vs-Debit answer, which is **per-market** per the requirements
doc's own answer to Open Question 1.

---

## 7. What is still genuinely blocked

Nothing about the port. The **file specification** is the only hard external
dependency, and it blocks compliance, not construction:

1. Which jurisdiction first (UAE MOHRE / Saudi / Bahrain WSI) — formats and
   reporting obligations differ.
2. Direct regulator integration or via a bank/exchange-house intermediary. The
   requirements doc answers *"design to support all"*, which is a product
   position, not a file layout.

Both were open in July and remain open. Neither prevents porting the pipeline,
the lifecycle, the exception handling or the screens — and doing that work now
is what stops it being deleted.
