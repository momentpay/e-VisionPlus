# Migration — Remove the wallet-app dependency

| Property | Value |
|---|---|
| Date | 2026-08-01 (**revised same day — see §0**) |
| Status | **Planned, not started. §0 must be resolved before §3 is executed** |
| Decision | [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md) — wallet-app is retired; muNSwitch and mw-core stay |
| Size | Small **at the call-site level**; §0 adds a real merge problem on top |
| Risk | Two genuine risks: §0.3 (losing the Chart of Accounts registry) and §3 step 3 (money units) |

---

## 0. ⚠️ Correction — this is not a clean removal, it is a three-way merge

**Added after checking Avenza, 2026-08-01.** The plan below was originally scoped against standalone `vmu_core` alone. That was incomplete. Three findings change it.

### 0.1 `wallet_gl` is identical in both trees — the GL upgrade is *not* in wallet_gl

`Avenza/apps/wallet_gl` and `wallet-app/apps/wallet_gl` are **byte-identical modulo line endings** (Avenza LF, wallet-app CRLF). Every file "differs" under a naive `diff` and none differs in substance. The GL work done in Avenza is in its **`vmu_*` apps**, not in `wallet_gl`.

### 0.2 Avenza's `vmu_*` GL code is ahead of `vmu_core` — M5 Phase 1–3, dated 2026-07-18, never ported back

| File | `vmu_core` | Avenza | What Avenza has that we don't |
|---|---|---|---|
| `fas/gl/vmu_core_gl_adapter.ex` | 206 lines | **328** | `register_reconciliation_mirror/4` — registers each posting in `WalletGl.GlPostingStore` *after* the CMS transaction commits, as a reconciliation/observability mirror feeding `GlReconciliationJob`'s `cms_ledger_entries`-backed drift check. Plus configurable repo/schema via `compile_env` |
| `fas/gl/card_account_codes.ex` | 84 lines | **94** | Reduced to a compatibility shim; `valid?/1` and `all/0` delegate to the canonical registry |
| `fas/gl/gl_reconciliation.ex` · `trial_balance.ex` | 104 · 176 | 105 · 178 | Minor |

Avenza's own note records that the ADR-003 co-deployment blocker was misdiagnosed: `WalletGl.Application` had been running all along, and the real blocker was `WalletDatabase.Repo` sitting behind a stale `start_repo: false`.

### 0.3 The canonical Chart of Accounts lives in `wallet_gl` — retiring it would lose a 26-account registry

`WalletGl.ChartOfAccounts` is **not a stub**. It is a real registry: `default_accounts/0` returns **26 accounts** with `code`, `name`, `account_class`, `normal_balance`, **`owner_app`**, `currency`, `active` and `description`, plus `register/2` for extension and `valid?/1` for validation.

```
1001 Card Receivables · 1002 Cash Advance Receivable · 1003 Accrued Interest Receivable
1004 Fee Receivable · 1005 Charged-Off Receivable · 1006 HCS Employee Pool Receivable
1007 ITS Interchange Receivable · 1008 ITS FAR Receivable · 2001 Customer Credit Liability
2002 HCS Parent Account Payable · 2003 ITS FAR Payable · 3001 Payment/Adjustment Clearing
3003 Disputed Receivable · 3004 Scheme Recovery Clearing · 4001 Fee Revenue
4002 Interest Income · 4003 Interchange Income · 4004 Recovery Income · 4005 ITS FAR Income
5001 Interchange/MDR Expense · 5002 ITS FAR Expense · 7001 LMS Provisioning Expense
7002 LMS Provisioning Liability · 7003 LMS Merchant Receivable
7004 LMS Merchant Settlement Income · 9001 Suspense
```

Accounts are attributed across `vmu_fas`, `vmu_cms`, `vmu_col`, `vmu_hcs`, `vmu_its`, `vmu_dps` and `vmu_lms`. Standalone `vmu_core` has **five codes in a module docstring**.

**Direction conflict.** Avenza's M5 work moved *toward* `WalletGl.ChartOfAccounts` as the canonical registry — deepening the wallet_gl dependency. [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md) retires wallet-app. These point opposite ways. The resolution is not to abandon either: **absorb `ChartOfAccounts` into `vmu_core` natively** (as `VmuCore.GL.ChartOfAccounts`) and retire the wallet_gl dependency around it. Deleting wallet_gl without porting this loses the registry.

### 0.4 A live GL misclassification exists in `vmu_core` today — real code, not a comment

```elixir
# vmu_core/lib/vmu_core/fas/gl/card_account_codes.ex
def journal_pair("INTEREST"), do: {@credit_liability, @fee_revenue}   # 4001 Fee Revenue

# Avenza — fixed 2026-07-18
def journal_pair("INTEREST"), do: {@credit_liability, "4002"}         # 4002 Interest Income
```

**Standalone `vmu_core` books interest income into the Fee Revenue account.** Interest and fee income are commingled and cannot be separated in the trial balance — a financial-reporting defect, not a cosmetic one. Avenza fixed it; the fix never came back.

**This should be fixed on its own merits, immediately, independent of this migration.** Do not bundle it into a dependency-removal commit.

### 0.5 The divergence runs *both* ways — do not "just port Avenza"

`InternalGlPoster` is **332 lines in `vmu_core` versus 100 in Avenza**. `vmu_core` has ten posting functions Avenza lacks — `post_debit_deposit/purchase/adjustment`, `post_prepaid_load/spend/adjustment`, `post_wallet_load/withdrawal` — the Way4 Phase 1 Debit/Prepaid/Wallet work, built here after the platform-of-record reversal.

So neither tree is simply newer:

| | Ahead in |
|---|---|
| **Avenza** | Chart of Accounts registry · interest→4002 fix · reconciliation mirror · configurable repo/schema |
| **`vmu_core`** | Debit / Prepaid / Wallet posting (10 functions) · everything from Way4 Phase 1 |

**Consequence: this is a selective three-way merge, not a directional port.** Porting Avenza wholesale would silently delete Debit, Prepaid and Wallet posting. That is the same class of loss [VMU-ADR-001](../decisions/001-platform-of-record.md) exists to prevent — this is its eleventh recorded instance.

### 0.6 Revised sequence

| | Work | Independent of the migration? |
|---|---|---|
| **0a** | Fix `journal_pair("INTEREST")` → `4002` | **Yes — do first, alone** |
| **0b** | Absorb `ChartOfAccounts` into `VmuCore.GL.ChartOfAccounts` (26 accounts, `owner_app`, `register/2`, `valid?/1`); repoint `CardAccountCodes` at it | Prerequisite for §3 step 5 |
| **0c** | Decide on `register_reconciliation_mirror/4` — it mirrors into `WalletGl.GlPostingStore`, which is being retired. Either drop it, or reimplement the drift check natively against `cms_ledger_entries` | Prerequisite for §3 step 4 |
| **0d** | Audit the remaining `vmu_core` ↔ Avenza GL diffs for anything else missed | **Yes — do before §3** |
| **1–6** | The dependency removal in §3 below | After 0a–0d |

---

## 1. Scope

Remove all dependence on `../wallet-app` so `vmu_core` builds and runs without it.

**Scope correction worth noting:** the decision named `wallet_gl`, `wallet_cards` and `wallet_database`. `mix.exs` actually carries **six** wallet-app dependencies. Since wallet-app is being retired outright, all six are in scope — the other three (`wallet_shared_kernel`, `wallet_events`, `wallet_observability`) would otherwise be left behind as orphaned dependencies on a retired product.

```elixir
# mix.exs — all six to be removed
{:wallet_cards,         path: "../wallet-app/apps/wallet_cards",         override: true},
{:wallet_gl,            path: "../wallet-app/apps/wallet_gl",            override: true},
{:wallet_shared_kernel, path: "../wallet-app/apps/wallet_shared_kernel", override: true},
{:wallet_observability, path: "../wallet-app/apps/wallet_observability", override: true},
{:wallet_events,        path: "../wallet-app/apps/wallet_events",        override: true},
{:wallet_database,      path: "../wallet-app/apps/wallet_database",      override: true},
```

Out of scope: `../muNSwitch`, `../mw-core`, `../tmsuat_apps-main` — all retained per VMU-ADR-004.

---

## 2. Measured coupling

Searched across `lib/`, `test/` and `config/`. This is the complete surface, not an estimate.

| Dependency | Real code usage | Verdict |
|---|---|---|
| `wallet_cards` | **None** | Dead — delete outright |
| `wallet_observability` | **None** | Dead — delete outright |
| `wallet_events` | **None** | Dead — delete outright |
| `wallet_database` | **None.** One mention in `config/config.exs:63`, a comment stating the repo is *not* needed | Dead — delete outright |
| `wallet_shared_kernel` | `WalletSharedKernel.Money` in **2 files** | Absorb (55 lines) |
| `wallet_gl` | `GlAdapter` (behaviour), `GlPostingRecord` (struct) in **2 files** | Absorb the two, discard the rest |

### 2.1 The two files that matter

**`lib/vmu_core/fas/settlement_posting_adapter.ex`**
```elixir
alias WalletGl.GlPostingRecord
alias WalletSharedKernel.Money
# …
money = Money.new(minor_units, currency)
{:ok, record} = GlPostingRecord.new(key, posting_date, entries, "vmu_core_gl", correlation_id: …)
VmuCoreGlAdapter.post_entry(record, nil)
```

**`lib/vmu_core/fas/gl/vmu_core_gl_adapter.ex`**
```elixir
use WalletGl.GlAdapter          # behaviour
alias WalletGl.GlPostingRecord  # struct
# 9 × @impl WalletGl.GlAdapter callbacks
```

### 2.2 References that are comments only — no code change needed

| Location | What it says |
|---|---|
| `cms/purchase_posting.ex:7` | Moduledoc mentions `WalletGl.GlPostingRecord` |
| `col/settlement_command.ex:31` | Comment: "reconciled onto `WalletGl.ChartOfAccounts`" |
| `col/write_off_processor.ex:30` | Same comment |
| `config/config.exs:63` | Comment explaining `WalletDatabase.Repo` is not needed |

`WalletGl.ChartOfAccounts` is **never called** — only named in two historical comments. Reword them during the migration so they stop pointing at a retired product.

### 2.3 Only one of nine behaviour callbacks is used

`VmuCoreGlAdapter` implements nine `WalletGl.GlAdapter` callbacks. Searching for callers finds exactly one, from one place:

```
lib/vmu_core/fas/settlement_posting_adapter.ex:269:    case VmuCoreGlAdapter.post_entry(record, nil) do
```

The other eight are dead. They exist because [VMU-ADR-012](../decisions/README.md#42-authorization--switch-was-adr-001003-fas-tracker) kept the behaviour "for contract compliance" with a pipeline that would be enabled at co-deployment. There is no co-deployment, and contract compliance with a retired application has no value.

**Therefore: do not port the behaviour. Delete it.** `VmuCoreGlAdapter` becomes a plain module exposing `post_entry/2`.

---

## 3. Plan

Each step is independently committable and independently verifiable. Do them in order — step 1 shrinks the problem before anything risky is touched.

### Step 1 — Delete the four dead dependencies

Remove `wallet_cards`, `wallet_observability`, `wallet_events`, `wallet_database` from `mix.exs`. Reword the `config/config.exs:63` comment.

*Verify:* `mix deps.get && mix compile --warnings-as-errors` — clean, no new warnings.
*Risk:* none. Nothing references them.

### Step 2 — Absorb `GlPostingRecord` as a native struct

Create `VmuCore.FAS.GL.PostingRecord` mirroring the fields `SettlementPostingAdapter` actually populates: posting key, posting date, entries (`account_code`, `description`, `debit_amount`, `credit_amount`, `cost_center`, `reference`), source, `correlation_id`, and status.

Port only what is used. The upstream struct also carries retry/backoff and lifecycle states for an external GL provider; `VmuCoreGlAdapter` writes to the internal ledger and needs none of it.

*Verify:* settlement posting produces identical `cms_ledger_entries` rows against a real Postgres database, before and after.

### Step 3 — Replace `WalletSharedKernel.Money` ⚠️ **the one real risk**

`Money` is a 55-line integer-minor-units value type. `vmu_core`'s own convention is **`Decimal`, never float, never minor units** — stated as a hard rule in `CLAUDE.md`. So this is a representation change, not a copy.

The conversion happens at exactly one place, `settlement_posting_adapter.ex:255`:

```elixir
minor_units = amount |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
money       = Money.new(minor_units, currency)
```

**Recommended: delete `Money` rather than port it.** Carry `Decimal` end-to-end into the posting record and drop the minor-units round trip entirely. That removes a conversion instead of relocating it, and aligns the path with the rest of the codebase.

**Why this is the risk step.** This codebase has already shipped a Decimal-versus-integer amount-unit mismatch bug once (found during CU-2). A silent factor-of-100 error in settlement posting is the highest-consequence defect this migration could introduce. Do not batch this step with others, and verify against real ledger rows rather than unit tests alone.

**Latent defect to check while here — do not fix silently.** The `× 100` is hardcoded, which assumes every currency has two decimal places. It is wrong for 3-decimal currencies (KWD, BHD, OMR) and for 0-decimal ones (JPY). Whether it matters depends on which currencies actually reach this path — `currency` defaults to `"AED"`. Confirm before deciding whether this is a live bug or a latent one, and raise it as its own item either way.

### Step 4 — Drop the `GlAdapter` behaviour

Remove `use WalletGl.GlAdapter` and the eight unused callbacks. Keep `post_entry/2` as a plain public function.

*Verify:* `mix compile --warnings-as-errors`; confirm `SettlementPostingAdapter` is still the only caller.

### Step 5 — Remove the last two dependencies and reword stale comments

Remove `wallet_gl` and `wallet_shared_kernel` from `mix.exs`. Update the `ChartOfAccounts` comments in `col/settlement_command.ex` and `col/write_off_processor.ex`, and the moduledoc in `cms/purchase_posting.ex`.

*Verify:* `grep -r "Wallet" lib/ config/` returns nothing; `mix deps.get` resolves with `../wallet-app` absent or renamed. **Test the build with the directory actually moved aside** — a `path:` dependency that is merely unreferenced still resolves while the directory exists.

### Step 6 — Update the documentation

- [VMU-ADR-012](../decisions/README.md#42-authorization--switch-was-adr-001003-fas-tracker) → note the behaviour was dropped
- [Ownership map §4.9](Kosa_Domain_Ownership_Map.md) → remove the wallet-app row, leaving three external repositories
- [VMU-ADR-004](../decisions/004-external-dependency-boundaries.md) → mark the wallet-app retirement complete
- `CLAUDE.md` → its source-repo section still describes wallet-app as a primary source for CMS

---

## 4. What this migration does *not* fix

**The chart of accounts gap becomes more visible, not worse.** Two COL comments reference `WalletGl.ChartOfAccounts` (277 lines) as a reconciliation target. Nothing calls it — vmu_core's real chart of accounts is `FAS.GL.CardAccountCodes`, five account codes in a module docstring. Removing the reference does not change behaviour, but it removes the illusion that a richer chart of accounts is available somewhere.

That gap is tracked separately as item **A2** in [`compare/Kosa_Handbook_Alignment_Assessment.md`](../compare/Kosa_Handbook_Alignment_Assessment.md) — chart of accounts as data, plus accounting periods. This migration is a good moment to schedule it, but they are separate pieces of work and should not be merged.

---

## 5. Estimate

| Step | Effort | Risk |
|---|---|---|
| 1 — delete four dead deps | Minutes | None |
| 2 — absorb `PostingRecord` | ~1 hour | Low |
| 3 — replace `Money` with `Decimal` | ~2 hours + real-data verification | **Medium — the only real risk** |
| 4 — drop the behaviour | ~30 minutes | Low |
| 5 — remove deps, reword comments | ~30 minutes | Low |
| 6 — documentation | ~30 minutes | None |

Roughly half a day. The distribution matters more than the total: **step 3 carries nearly all the risk and should be committed and verified alone.**
