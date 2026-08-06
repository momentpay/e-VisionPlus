# WPS (Wage Protection System) Cards — Product Feasibility & Requirements

**Status:** 📝 Not started **in vmu_core** — still zero references, re-confirmed
2026-08-06. **⚠ Correction, 2026-07-11 (same day): a real, substantial
implementation already exists in the sibling `wallet-app` repo**
(`apps/wallet_wps/`) — not a scaffold. It has a genuine multi-format file
parser (CSV/fixed-width/Excel-stub), a `SalaryCredit` entity with a full
status lifecycle (`parsed→validated→pending→posted→failed→settled`),
gross/net/deduction consistency validation, idempotent batch posting (keyed
on `payment_reference`), an exception queue for failed postings, audit-event
emission, and real tests (`salary_credit_batch_pipeline_test.exs`,
`post_salary_credit_test.exs`). It posts into `wallet_ledger`/`wallet_accounts`
via injected `beneficiary_resolver`/`ledger_poster` functions (the project's
established DI pattern for cross-app calls).

> **⚠ Recommendation reversed, 2026-08-06.** The paragraph below said *"do not
> rebuild this in vmu_core; treat `wallet_wps` as the real starting point"*. That
> is now wrong on both counts:
>
> - [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md) (accepted
>   2026-08-01) **retires wallet-app**, so the recommendation pointed at a
>   codebase scheduled for deletion. `wallet_wps` was never a dependency of
>   `vmu_core` either — it has never appeared in `mix.exs`.
> - The underlying reasoning ("WPS needs a balance-based disbursement target")
>   still holds, but vmu_core now **has** that: Prepaid and Debit are
>   first-class GL products, cut over, with their own posting rules. Phase W1's
>   hard dependency is satisfied.
>
> The real state is richer *and* weaker than the note below implies. About
> **6,400 lines** exist across three apps — including four LiveView admin
> screens the note does not mention — but the **parser is not a WPS parser**: it
> is a generic salary-file parser with an invented fixed-width layout, a `USD`
> default, no `EDR`/`SCR` record types, and the acronym mis-expanded as "Worker
> Payment System".
>
> **See [`WPS_Port_Gap_Analysis.md`](WPS_Port_Gap_Analysis.md)** for what to
> port, what to rewrite, and what to discard. The task is a port into vmu_core
> before wallet-app is deleted — not a from-scratch build, and not a dependency.

<details>
<summary>Original 2026-07-11 recommendation (superseded)</summary>

**Recommendation: do not rebuild this in vmu_core.** Everything in §3-6 below
was written from vmu_core's perspective before this was found, and the
underlying analysis (WPS needs a balance-based disbursement target, not a
credit-line one) still holds — it's exactly *why* wallet-app's existing
`wallet_accounts`/`wallet_ledger` is the better foundation, and why this is
already built there. Treat `wallet_wps` as the real starting point; the
open question isn't "build WPS," it's "does `wallet_wps`'s file format match
the specific regulator/market this needs, and does its `SalaryCredit` model
need extending for UAE MOHRE-specific reporting" — a gap-analysis task
against real code, not a from-scratch build. The rest of this document is
kept for its architectural reasoning, not as an active build plan.

</details>

---

## 1. Purpose & Scope

WPS is a UAE (and similarly-named schemes in Saudi Arabia/Bahrain/others)
regulatory mandate: employers above a certain size **must** pay employee
wages electronically through an MOHRE-approved system, with the payment file
and its execution reported back to the regulator. A "WPS card" is the
practical instrument for the (often large) population of workers who don't
have — or aren't eligible to easily open — a traditional bank account: the
employer's salary file disburses into a card-based account instead of a
bank IBAN.

**Boundary test:** WPS is not a fourth kind of *value model* — the card
itself is almost always built on a Prepaid or Debit account underneath (see
those two docs). What WPS actually adds is (a) a **regulated bulk salary
file ingestion + disbursement pipeline**, (b) **mandatory reporting back to
the regulator** on whether/when each employee was paid, and (c) specific
KYC/eligibility rules for the worker population it serves (often lower-wage,
higher-turnover, may lack standard ID documents in some cases). Get the
account model question answered by Prepaid/Debit's planning first — WPS
is additive on top of whichever one is chosen.

## 2. Where This Sits

| Direction | Module | Contract |
|---|---|---|
| ← Employer | Salary file | Bulk file (SIF — Salary Information File format, or bank-specific equivalent) listing employee, wage amount, pay period |
| → Prepaid/Debit account | Disbursement | Each file line credits the corresponding worker's card account |
| → Regulator (MOHRE or equivalent) | Compliance reporting | Confirmation of successful/failed disbursement per employee, per cycle |
| ← CIF | Worker identity | WPS-specific eligibility/KYC rules may differ from standard CIF onboarding |
| → HCS (conceptually adjacent, not the same) | Bulk-issuance pattern | HCS already has a real bulk employee-card-issuance concept (`Company`/`EmployeeCard`) — the *mechanics* of "one employer, many employee cards, funded from a central source" are structurally similar even though HCS is a corporate credit product and WPS is a salary-disbursement product. Worth reusing the bulk-issuance UX pattern, not the credit logic. |

## 3. What's Genuinely Reusable

- **HCS's bulk employee-card-issuance pattern** (`Company` → many
  `EmployeeCard` rows) — the *shape* of "one employer entity onboards many
  worker cards under it" already exists and is real, tested code (see the
  HCS module review, 2026-07-11) — even though HCS itself is a corporate
  *credit* product and not reusable as-is for WPS's salary-disbursement
  model, the employer/employee-roster structure is a useful precedent to
  design against rather than starting from a blank page.
- **CTA's card entity + lifecycle** — same as every other product in this
  batch; card issuance/activation/block/replace is product-agnostic.
- **Whatever account model Prepaid or Debit builds** — WPS cards are
  disbursement targets on top of one of those, not a new value model.
- **ASM, Module Configuration Framework, ParameterEngine** — fully reusable.
- **Broadway** (already a project dependency, used for TRAMS's high-throughput
  clearing pipeline) is the natural fit for ingesting a bulk employer salary
  file the same way TRAMS ingests IPM/Base II files — architecturally
  identical problem (parse a batch file, process N rows, produce a
  reconciliation report), different domain.

## 4. Net-New Build Required

| Area | What's needed |
|---|---|
| Salary file ingestion | Parser for the WPS SIF format (or the specific bank/exchange-house format the employer relationship dictates) — a real vendor/regulator file spec is needed before this can be built accurately, same caution as this session's ITS/DPS work: don't guess a file format, get the real spec |
| Employer onboarding | An "employer" entity distinct from HCS's `Company` (WPS employers aren't necessarily commercial-card customers) with a worker roster |
| Bulk disbursement | Credit each worker's card account from the employer's funding source, per file line, with per-line success/failure tracking |
| Regulatory reporting | Generate and (eventually) transmit the compliance report back to MOHRE or the exchange-house intermediary confirming disbursement |
| Worker eligibility/KYC | WPS-specific onboarding rules — may need lighter-KYC handling similar to Prepaid's tiering question |
| Exception handling | Failed disbursements (bad account, worker left the company, file errors) need a real remediation workflow, not silent drops — this is the kind of "reconciliation matters" problem this project has gotten right elsewhere (TRAM's matching engine, DPS's evidence trail) |

## 5. Feature Inventory (draft — validate with product/compliance before build)

| FR | Feature |
|---|---|
| 001 | Employer onboarding + worker roster management |
| 002 | Salary file ingestion (format TBD — needs real spec) |
| 003 | Per-line disbursement to worker card accounts (Prepaid or Debit, per that decision) |
| 004 | Per-line success/failure tracking + exception/remediation workflow |
| 005 | Regulatory compliance report generation (and, later, transmission) |
| 006 | Worker card issuance under an employer (bulk), reusing the HCS bulk-issuance UX pattern |
| 007 | Worker eligibility/KYC rules specific to the WPS population |
| 008 | Cardholder self-service: balance, ATM withdrawal, minimal transaction history (workers in this population skew toward cash-out-heavy usage) |
| 009 | Employer-side reporting: who got paid, who didn't, why |

## 6. Phased Implementation Plan (high-level — refine before starting, and only after Prepaid/Debit's account-model decision lands)

1. **Phase W1 — Prerequisite: account model.** WPS cannot start meaningfully
   until Prepaid or Debit (whichever the business picks as the underlying
   account) has its ledger/balance model built — this is a hard dependency,
   not a nice-to-have sequencing preference.
2. **Phase W2 — Employer + worker roster.** Employer entity, worker roster,
   card issuance under an employer (adapting HCS's bulk-issuance pattern).
3. **Phase W3 — File ingestion + disbursement.** Get the real file spec
   first; build the Broadway-based parser + per-line disbursement +
   exception tracking together, since exception handling is not a
   follow-up, it's core to what makes this a *compliance* system.
4. **Phase W4 — Regulatory reporting.** Compliance report generation;
   transmission mechanism depends on whether the bank integrates directly
   with the regulator or through an exchange-house intermediary (a business
   relationship question, not a technical one).
5. **Phase W5 — Ops UI + cardholder self-service.**

## 7. Open Questions (need product/business/compliance input before W1 starts)

1. **Prepaid or Debit as the underlying account?** This gates everything —
   answer Prepaid/Debit's own open questions first.
   >>Answer: This has to be as per implementation for the country: UAE MOHRE WPS: Historically prepaid-heavy, but banks increasingly push debit accounts for migrant workers (to deepen banking penetration).Saudi WPS: More account-centric; debit fits better.Bahrain WSI: Similar to Saudi, expects account-based flows.
2. Which jurisdiction's WPS-equivalent scheme (UAE MOHRE WPS, Saudi WPS,
   Bahrain WSI, others) — file format and reporting obligations differ.
   >>Answer: We have to be open as per market as we are building the product
3. Direct regulator integration, or via a bank/exchange-house intermediary
   that already has the regulatory relationship? This materially changes
   scope — a direct integration needs real regulator API/file-transfer
   credentials (same "don't build against a guessed spec" caution as the
   Mastercom work).
   >>Answer: This product is getting built for Exchange house or banks and so we need to design with product perspective to support all.
4. Worker KYC: what identity documents are acceptable for this population,
   and does it differ from standard CIF onboarding?
   >>Answer:We can define the KYC as per the KYC methods
5. Is ATM cash-out the primary usage pattern to design for (common for this
   population), which would prioritize cash-access UX over card-present
   retail spend?
 Answer: Agree but it can pass through FAS for authorization , in that case either ATM or Card present all are acceptable, Debit or Prepaid all are same.