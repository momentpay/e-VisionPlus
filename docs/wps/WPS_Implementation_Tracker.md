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

## Phase W2 — Ingestion ✅ 2026-08-06

### Built

| | |
|---|---|
| `wps.employer_config` | Per-employer layout: format, mapping, positions, date and amount encoding |
| `wps_files` | The ingested file: hash, counts, totals, layout snapshot, parse errors |
| `wps_salary_credits` | One row per line, with a guarded status lifecycle |
| `WPS.FileParser` | Config-driven CSV and fixed-width parsing |
| `WPS.AmountFormat` | `decimal` and `implied_2dp` encodings |
| `WPS.Ingestion` | Parse, validate, persist — **no disbursement** |
| 38 tests | 26 parser, 12 ingestion |

### The missing SIF spec is no longer a blocker

Nothing in the parser knows any scheme. Column names, positions, date format
and amount encoding all come from `wps.employer_config`, exactly as
`COL.AgencyDesk` does for collections-agency files. **Onboarding a new market
is a configuration entry, not a code change.**

### Decisions worth recording

**Amount encoding is configured, never inferred.** `"1234"` is a valid amount
under both encodings — `1234.00` as a decimal, `12.34` as implied minor units.
A hundredfold difference, with nothing in the string to say which is right.
Inference here would be a coin flip on every worker's wage, so `amount_format`
is explicit and a decimal point under `implied_2dp` is an error rather than a
silent reinterpretation.

**An unconfigured employer is refused, not defaulted.** Guessing a layout is how
amounts land in the wrong column.

**`net = gross - deductions` is validated when all three are present.** A file
failing this is almost always a column-mapping error, which makes it the
cheapest available check that the layout config itself is right — and far better
to catch before the money moves than after.

**The layout is snapshotted onto the file, not referenced.** Config changes; an
operator investigating a file months later needs to know how it *was* parsed,
or the parse is not reproducible.

**Errors accumulate; parsing never aborts.** A file that reads 383 of 400 lines
is ingested with the 17 failures listed. Refusing the whole file would discard
383 correct payment instructions over someone else's typo and leave the operator
with no list of what to fix.

**Ingestion does not disburse.** That is W3, behind a pre-flight report. Keeping
them apart is what makes it safe to ingest a file simply to look at it.

### Found while building

**The CSV splitter was not quote-aware.** A naive split on the delimiter tore
`"12,500.75"` into two fields — silently, leaving a plausible number in each.
Payroll exports quote thousands separators routinely, so this would have
corrupted the one column that must never be wrong. Caught by test; the splitter
now respects quotes and doubled-quote escapes.

**A configurable policy cannot also be a database constraint.** The file-hash
index started as `unique`, which contradicted `duplicate_file_policy: "warn"`.
Relaxed to a plain index, with the policy enforced in code.

The guarantee that actually stops a double payment is unchanged and remains a
hard constraint: **unique `(employer_id, payment_reference)`**. That one is an
invariant, not a policy, which is exactly why it belongs in the database.

**`parse_errors` returned different shapes** depending on whether the caller
held the in-memory struct (atom keys) or a reloaded one (string keys, via
jsonb). Now stringified at write time.

---

## Phase W3 — Disbursement and the exception queue ✅ 2026-08-06

### Built

| | |
|---|---|
| `WPS.Disbursement.pre_flight/1` | What would happen, with nothing at stake |
| `WPS.Disbursement.post_batch/2` | The money moves |
| `WPS.Disbursement.retry/2` / `abandon/3` | Remediation |
| `wps_salary_credit_exceptions` | The queue, classified by cause |
| `WPS.SalaryCreditException` | Five classifications, mapped from resolver errors |
| 16 tests | Real Postgres, real posting engine |

### Two guarantees, proved rather than asserted

**A re-run does not pay twice.** Two independent guards: a status check that
skips lines already `POSTED`, and an idempotency key derived from the employer's
own `payment_reference`, which is unique per employer in the database. A test
forces the status back to `PARSED` to prove the second guard holds on its own —
the balance does not move again.

**One bad line does not stop the batch.** An unlinked worker gets an exception;
the other lines are still paid. That is the entire reason a payroll run needs a
queue rather than a rollback.

### Decisions worth recording

**Money moves through `CMS.PrepaidLedger.load/1`**, not by posting GL directly.
`load/1` writes the prepaid ledger entry and the GL posting in one transaction,
and it is the entry point every other prepaid funding path uses — the same
discipline COL follows in routing payments through `CMS.PaymentIntake`.

**Resolution runs twice.** Once at pre-flight with nothing at stake, and again
at posting time, because the roster may have been fixed in between — which is
precisely the workflow the queue is meant to encourage.

**Exceptions are classified, not just recorded.** An operator fixes every
`BENEFICIARY_UNRESOLVED` line one way and every `ACCOUNT_INACTIVE` line another.
A flat list of four hundred failures is not a queue. `exception_summary/1`
groups by cause with the money at stake.

**One open exception per credit**, enforced by a partial unique index. Retries
update it in place and increment `attempt_count`, so the queue shows outstanding
work rather than a history of every attempt.

**`abandon/3` is separate from `retry/2`.** Deciding not to pay a worker is a
decision someone owns, and the note records who and why.

### Found while building

**`PrepaidLedger.load/1` was not idempotent.** It generated its own key with
`System.unique_integer`, so two calls made two loads — while `spend/3` already
accepted a key. That was the wrong way round: a duplicate spend is recoverable,
a duplicate load creates money. `load/1` now accepts `:idempotency_key`, and
without one behaves exactly as before.

**`failure_reason` is `varchar(300)` but was being handed a 500-character
string**, which raised a `Postgrex` error from inside a transaction rather than
returning a changeset error — one unpayable line taking down the whole batch.
Truncated at the call site and a `validate_length` added so it cannot recur
silently.

**`WPS_SALARY` was missing from the prepaid channel enum.** Added rather than
reusing `ADMIN_MANUAL`: a wage disbursement is a distinct funding channel, and
keeping it separate is what lets anyone ask *"how much of this balance is
protected wages"* — the question the whole scheme exists to answer.

---

## Phase W4 — Employer refunds and regulator reporting ✅ 2026-08-06

### Built

| | |
|---|---|
| `wps_refund_requests` | Maker-checker, one pending per payment |
| `WPS.Refunds` | `request/2`, `approve/3`, `reject/3` |
| `WPS.RegulatoryReport` | `generate/3`, `render/2` — CSV and JSON, config-driven |
| 19 tests | Real Postgres, real ledger |

### Refunds

**Two people, because this is the one operation that moves money against the
worker.** An employer overpaid, or paid someone who had already left — both are
real, and both are also what a fraudulent request would claim. The bank cannot
verify the employer's account of it, so the control is procedural: the requester
cannot approve their own request, and the maker/checker rule is enforced on the
record itself rather than only in the calling function.

**Spent wages cannot be recovered.** The refund consumes the prepaid balance, so
if the worker has spent it the request fails. That refusal is the right answer —
recovering it would mean driving a wage account negative.

**`FAILED` is deliberately distinct from `REJECTED`.** A rejection is a
judgement: someone looked and said no. A failure is the world refusing: the money
was gone. Marking a failed recovery `APPROVED` would be a lie in the audit trail,
and collapsing the two would lose the distinction an employer chasing an
overpayment most needs.

**Partial refunds are supported**, because the realistic case is an overpayment
— the employer meant to send 4,500 and sent 5,000.

**The GL posts `REVERSAL`, not `PURCHASE`.** For `WPS_PREPAID` the two share an
account pair, so only the event type distinguishes an employer recovery from the
worker's own spending. This is the first real use of the explicit `:event_type`
escape hatch added to `Posting.LegacyEvent` during GL C3.

**Order matters:** the balance is taken first and the GL posted only if that
succeeded. Posting first would record a recovery that then could not happen.

### Regulator reporting

**An unpaid worker is a first-class row, with the reason attached.** A Wage
Protection scheme exists to make non-payment visible, so a report listing only
successful payments would defeat the scheme it is filed under. The reason comes
from the exception queue, which carries the operator-facing explanation rather
than the credit's truncated summary.

**The period is the employer's stated pay date**, not our processing date —
otherwise the report is filed against our calendar rather than the wage cycle.

**Status uses the regulator's vocabulary**: `PAID` / `NOT_PAID`, not our internal
`POSTED` / `FAILED`.

**Output is configured**, via the same `export_mapping` / `file_format` /
`date_format` keys the import side uses. Column *order* stays canonical
regardless of mapping — only labels change, so two employers' reports stay
structurally comparable.

**Not transmitted.** Whether the institution files directly with the regulator or
through an exchange house holding the relationship is a business arrangement,
and remains an open question in the requirements. Generating without
transmitting is the honest half to build.

---

## Phase W5 — Admin UI, menu entry, ASM permissions

---

## Still blocked externally

The real file specification — which jurisdiction first, and direct-regulator
versus exchange-house intermediary. It blocks **compliance**, not construction:
W2's mapper is designed so a layout is configuration rather than code.
