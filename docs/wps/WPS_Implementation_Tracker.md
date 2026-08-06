# WPS — implementation tracker

| Property | Value |
|---|---|
| Started | 2026-08-06 |
| Approach | **Native build in vmu_core**, aligned with the other modules |
| Not | A port of `wallet_wps` — see [`WPS_Port_Gap_Analysis.md`](WPS_Port_Gap_Analysis.md) |
| GL product | **`WPS_PREPAID`** (decided 2026-08-06) |

---

## Why native rather than a port

The gap analysis measured `wallet_wps` at ~6,400 lines. Removing what cannot
come across leaves design, not code:

- Six ETS+GenServer stores — wrong idiom here, and they buy nothing for
  bulk-load/bulk-post batch work.
- `TypedId`, `Money`, `DomainEvent`, `AuditEvent` — all have vmu_core equivalents.
- The parser's field layout — **guessed**, and must be rewritten regardless.

What *is* worth having is read across as requirements: the pipeline shape, the
status lifecycle, exception classification, and the employer refund
maker-checker. That is reading, not porting.

---

## The account model question, settled

**`WPS_PREPAID`, one product label**, with the underlying instrument a
per-employer configuration choice.

The concern raised was ATM cash-out — whether workers withdrawing cash forces a
debit account. It does not:

- `FAS.Authorization` already has `run_prepaid_authorization/1`; prepaid
  authorizes through FAS like any other product.
- `"atm"` is already a first-class channel in `FAS.SettlementPostingAdapter`.
- Money leaves the stored-value liability identically whether the terminal is an
  ATM or a POS.

The requirements doc reached the same conclusion in its own answer to Open
Question 5: *"it can pass through FAS for authorization, in that case either ATM
or Card present all are acceptable, Debit or Prepaid all are same."*

Cash-out remains a **reporting** concern, which is why `WITHDRAWAL` is a
separate event (below) even though its account pair matches `PURCHASE`.

---

## Phase W1 — Employer, roster, GL registration ✅ 2026-08-06

### Built

| | |
|---|---|
| `wps_employers` | Employer entity, institution-scoped, with a generic `regulator_id` |
| `wps_beneficiary_links` | The roster: employer's `employee_id` → prepaid account |
| `VmuCore.WPS.Employer` / `BeneficiaryLink` | Schemas with guarded statuses |
| `VmuCore.WPS.Roster` | Onboarding, linking, `resolve/2`, `resolve_many/2`, suspension |
| GL account `2007` | WPS Salary Disbursement Liability, owner `vmu_wps` |
| 6 posting rules | `WPS_PREPAID`: DEPOSIT, PURCHASE, **WITHDRAWAL**, REVERSAL, ADJUSTMENT_CREDIT/DEBIT |
| `InstitutionResolver` | WPS overlay on `cms_prepaid_accounts` |
| `Posting.Cutover` | `WPS_PREPAID` added — engine authoritative |
| 16 tests | Real Postgres |

### Decisions worth recording

**An employer is not an `HCS.Company`.** They share a shape — one organisation,
many workers, funded centrally — but not a meaning. An HCS company is a *credit*
customer holding a facility its employees spend against. A WPS employer is a
*disbursement counterparty* that pushes its own money out and owes the bank
nothing. Reusing `HCS.Company` would have meant carrying a `credit_limit` never
consulted and a `liability_model` that does not apply.

**The roster *is* the beneficiary link.** No separate worker table: a worker
matters to WPS once there is somewhere to pay them, which is exactly what the
link records.

**`employee_id` is unique per employer, not globally.** It is the employer's
key, not ours — two employers may both number staff from "001". Getting this
wrong would pay one company's worker from another company's file.

**`UNVERIFIED` links exist deliberately.** A salary file is the first the bank
hears of most of these workers. Refusing to record a line until an account
exists would discard the only evidence the worker is owed anything. So the line
is recorded, the link is unverified, and the disbursement goes to the exception
queue (W3) rather than being dropped.

**Account `2007` is separate from `2005` Prepaid Stored-Value Liability**
because salary float is regulated money with a reporting obligation to a labour
authority. A regulator asking what the bank holds on behalf of workers must not
be answered with a number that also includes gift-card balances.

**`WITHDRAWAL` shares an account pair with `PURCHASE`, and still earns its own
event.** Both move money out of the salary liability into cash clearing. The
event is separate because this population is cash-out heavy, that is the
headline metric for a WPS programme, and `posting_sets.event_type` is what makes
it queryable. A shared account pair is not a reason to collapse two events that
answer different questions.

### Found while building

**An overlay-cache defect, caught by its own test before shipping.** The
`InstitutionResolver` overlay cache was keyed on `account_ref` alone, so asking
the HCS question about a prepaid account cached a negative that then poisoned
the WPS answer. Same shape as the institution-cache bug in that module's own
moduledoc — *a cache whose key is narrower than its question*. Now keyed on
`{base_table, account_ref}`.

**`gl_extractions` was missing from the test database**, and `CoreBankingAdapter`
has **no test coverage at all** — C3 verified it against dev data only. Table now
applied; the coverage gap is real and open.

### Known, deliberate

**An existing prepaid account that later joins a roster splits its history**:
prior float sits in `2005`, new salary in `2007`. The normal case is an account
opened *for* the salary programme, where this never arises. If it matters for a
migrated portfolio, the HCS history relabel
(`priv/repo/relabel_hcs_history.exs`) is the working precedent.

---

## Phase W2 — Ingestion (next)

Config-driven layout mapping on the `COL.AgencyDesk` pattern, which already
solves this exact problem for collections agencies and whose moduledoc says
*"layouts genuinely vary by region/agency; a fixed schema per agency was the
wrong long-term shape"*.

`wps.employer_config`, scope `:bank`, keyed by employer code:
`import_mapping`, `date_format`, `amount_format`, `file_format`.

This is what turns the missing SIF specification from a blocker into
configuration — and it is what the requirements doc's own answer to Open
Question 2 asks for: *"we have to be open as per market as we are building the
product."*

## Phase W3 — Pre-flight report, batch disbursement, exception queue

## Phase W4 — Employer refunds (maker-checker), regulator reporting

## Phase W5 — Admin UI, menu entry, ASM permissions

---

## Still blocked externally

The real file specification — which jurisdiction first, and direct-regulator
versus exchange-house intermediary. It blocks **compliance**, not construction:
W2's mapper is designed so a layout is configuration rather than code.
