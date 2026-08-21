defmodule VmuCore.CMS.InternalGlPoster do
  @moduledoc """
  Legacy-shaped façade over `Posting.RuleEngine` (GL Phase C3).

  ## What changed in C3

  This used to insert a row into `cms_ledger_entries` and then mirror it to the
  posting engine. **It no longer writes that table at all.** `post/1` translates
  its legacy attrs into an engine event via `Posting.LegacyEvent` and returns
  the resulting journal entry.

  The module survives, rather than being deleted, because **thirty-five modules
  call it and none of them knows its own institution**. The engine needs
  `sys_id`/`bank_id`; a legacy call supplies an account id and nothing else.
  Deleting this façade would mean pushing `InstitutionResolver` into
  thirty-five call sites and changing every one of their signatures — more
  churn, more places to get it wrong, and no benefit. The name is now
  misleading (it posts to the engine, not to an internal table); renaming is
  deferred under VMU-ADR-003 along with every other rename.

  ## Return contract

  `{:ok, %Posting.JournalEntry{}}` with `posting_set` preloaded, instead of the
  old `{:ok, %CMS.LedgerEntry{}}`. The journal entry is the subledger row and so
  the true analogue. `{:error, :duplicate}` on a replayed idempotency key is
  preserved exactly — callers such as `PurchasePosting` branch on it.

  Callers that stored `entry.entry_id` in a `ledger_entry_id` column now store
  `entry.id`, a `journal_entries` id. Those columns carry no foreign key, so
  nothing breaks structurally, but the row they point at has moved.

  ## Chart of accounts

  **Remapped 2026-08-02 (Phase 4A) onto the single reconciled chart**,
  `VmuCore.GL.ChartOfAccounts`. This module previously defined its own code
  set inline, which conflicted with `FAS.GL.CardAccountCodes` while both
  wrote to `cms_ledger_entries` — 2001 meant "interest income" here and
  "Customer Credit Liability" there, 5001 meant a liability here and an
  expense there. See `docs/gl/Phase_4A_Account_Code_Remap.md`.

    1001 — Card Receivables            (asset)
    1002 — Cash Advance Receivable     (asset)
    1003 — Accrued Interest Receivable (asset)
    1004 — Fee Receivable              (asset)
    3001 — Payment / Adjustment Clearing (asset)
    4001 — Fee Revenue                 (revenue)
    4002 — Interest Income             (revenue)

  Stored value — Debit, Prepaid and Wallet — posts in the opposite
  direction from the receivable accounts above. A stored-value balance is
  money the bank **owes** the customer, so it is a liability, not a
  receivable (VMU-ADR-005):

    3005 — Bank Cash / Funding Clearing    (asset)   — was 1006
    2004 — Debit Deposit Liability         (liability) — was 5001
    2005 — Prepaid Stored-Value Liability  (liability) — was 5002
    2006 — Wallet Stored-Value Liability   (liability) — was 5003

  The old codes put stored value in the 5xxx expense range, where 5001 and
  5002 were already occupied by real expense accounts with the opposite
  normal balance, and 5003 was registered in no chart at all.

  Codes are referenced through module attributes rather than inline
  literals so a future change happens in one place; `test/gl/no_hardcoded_
  gl_codes_test.exs` enforces that no new literals appear elsewhere.
  """

  # Receivables / clearing
  @card_receivable      "1001"
  @interest_receivable  "1003"
  @fee_receivable       "1004"
  @payment_clearing     "3001"
  @cash_clearing        "3005"

  # Revenue
  @fee_revenue     "4001"
  @interest_income "4002"

  # Stored-value liabilities
  @debit_liability   "2004"
  @prepaid_liability "2005"
  @wallet_liability  "2006"

  import Ecto.Query, warn: false

  require Logger

  alias VmuCore.Repo
  alias VmuCore.Posting.{JournalEntry, LegacyEvent, RuleEngine}

  @doc """
  Post a journal entry. Returns {:ok, entry} or {:error, :duplicate} if
  the idempotency_key was already posted, or {:error, changeset} on validation failure.
  """
  def post(attrs) do
    with {:ok, event} <- LegacyEvent.from_attrs(attrs) do
      case RuleEngine.execute(event) do
        {:ok, set} ->
          Logger.debug(
            "[GL] posted #{attrs[:transaction_code]} #{attrs[:dr_amount]} " <>
              "key=#{attrs[:idempotency_key]}"
          )

          {:ok, journal_entry(set)}

        # A replayed key is not an error to the engine, but it is to every
        # caller here: the legacy contract was {:error, :duplicate}, and callers
        # such as `PurchasePosting` branch on it. Preserved exactly.
        {:ok, :duplicate, _set} ->
          {:error, :duplicate}

        {:error, :quarantined, exception} ->
          Logger.error(
            "[GL] posting quarantined key=#{attrs[:idempotency_key]} " <>
              "reason=#{exception.reason}"
          )

          {:error, {:quarantined, exception.reason}}

        {:error, reason} ->
          Logger.error(
            "[GL] posting REJECTED key=#{attrs[:idempotency_key]} reason=#{inspect(reason)}"
          )

          {:error, reason}
      end
    end
  end

  # The journal entry is the subledger row, and so the true analogue of the
  # `cms_ledger_entries` row this used to return. `posting_set` is preloaded
  # because the idempotency key lives there and callers read it.
  #
  # A posting set can hold several journal entries — one per product account —
  # but every legacy posting is single-account by construction, so there is
  # exactly one here.
  defp journal_entry(set) do
    JournalEntry
    |> where([j], j.posting_set_id == ^set.id)
    |> limit(1)
    |> preload(:posting_set)
    |> Repo.one()
  end

  @doc "Post interest charge for an account on a given date."
  def post_interest(account_id, amount, posting_date, idempotency_key) do
    post(%{
      account_id:       account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "INTEREST",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @interest_receivable,
      gl_account_cr:    @interest_income,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Monthly interest accrual"
    })
  end

  @doc "Post a fee charge (late fee, cash advance fee, annual fee)."
  def post_fee(account_id, amount, fee_type, posting_date, idempotency_key) do
    post(%{
      account_id:       account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "FEE",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @fee_receivable,
      gl_account_cr:    @fee_revenue,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Fee: #{fee_type}"
    })
  end

  @doc "Post a cardholder payment (reduces receivable, credits payment liability)."
  def post_payment(account_id, amount, posting_date, source_ref, idempotency_key) do
    post(%{
      account_id:       account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "PAYMENT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @payment_clearing,
      gl_account_cr:    @card_receivable,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Cardholder payment",
      source_ref:       source_ref
    })
  end

  @doc """
  Post a deposit/load into a debit account (Way4 parity plan Phase 1
  item 4, D2). `debit_account_id` here is a `CMS.DebitAccount.
  debit_account_id`, not a `CMS.Account.account_id` — `LedgerEntry.
  account_id` is a bare `:binary_id` with no DB-level FK, so this is
  safe (same cross-schema reuse `FAS.PendingHold` already relies on).
  """
  def post_debit_deposit(debit_account_id, amount, posting_date, channel, idempotency_key) do
    post(%{
      account_id:       debit_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "DEPOSIT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @cash_clearing,
      gl_account_cr:    @debit_liability,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Debit account funding: #{channel}"
    })
  end

  @doc """
  Post a cleared purchase against a debit account (Way4 parity plan
  Phase 1 item 4, D4) — the exact reverse direction of
  `post_debit_deposit/5`: the deposit liability (2004) decreases (DR),
  the offsetting credit is the bank's own cash position (3005) paying
  out to the network/merchant settlement. `available_balance` itself is
  NOT touched here — `CMS.DebitAuthorization.authorize/2` already
  decremented it in real time at approval (Debit has no OTB-then-settle
  two-phase balance model; the auth-time debit is final money movement,
  per this product's own confirmed v1 scope). This call only makes the
  already-reserved journal entry permanent once clearing confirms it.
  """
  def post_debit_purchase(debit_account_id, amount, posting_date, currency, idempotency_key) do
    post(%{
      account_id:       debit_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "PURCHASE",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @debit_liability,
      gl_account_cr:    @cash_clearing,
      currency:         currency || "AED",
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Debit card purchase settlement"
    })
  end

  @doc """
  Post a manual balance adjustment against a debit account (Card
  Products UX Parity Phase 1c, 2026-07-28). `direction: "CREDIT"` uses
  the same DR/CR shape as `post_debit_deposit/5` (increases
  available_balance); `direction: "DEBIT"` reverses it, same shape as
  `post_debit_purchase/5` (decreases available_balance).
  """
  def post_debit_adjustment(debit_account_id, amount, "CREDIT", posting_date, narrative, idempotency_key) do
    post(%{
      account_id:       debit_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "ADJUSTMENT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @cash_clearing,
      gl_account_cr:    @debit_liability,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end

  def post_debit_adjustment(debit_account_id, amount, "DEBIT", posting_date, narrative, idempotency_key) do
    post(%{
      account_id:       debit_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "ADJUSTMENT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @debit_liability,
      gl_account_cr:    @cash_clearing,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end

  @doc """
  Post a load into a prepaid account (Way4 parity plan Phase 1 item 5,
  P1) — same liability-direction shape as `post_debit_deposit/5`, its
  own GL code (2005, not 2004 — a different product).
  """
  def post_prepaid_load(prepaid_account_id, amount, posting_date, channel, idempotency_key) do
    post(%{
      account_id:       prepaid_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "DEPOSIT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @cash_clearing,
      gl_account_cr:    @prepaid_liability,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Prepaid account load: #{channel}"
    })
  end

  @doc """
  Post a cleared spend against a prepaid account (Way4 parity plan Phase
  1 item 5, P4) — exact reverse of `post_prepaid_load/5`. Ledger value
  movement already happened at authorization via `CMS.PrepaidLedger.
  spend/2`; this only makes the journal entry permanent.
  """
  def post_prepaid_spend(prepaid_account_id, amount, posting_date, currency, idempotency_key) do
    post(%{
      account_id:       prepaid_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "PURCHASE",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @prepaid_liability,
      gl_account_cr:    @cash_clearing,
      currency:         currency || "AED",
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Prepaid card purchase settlement"
    })
  end

  @doc """
  Post a manual balance adjustment against a prepaid account (Card
  Products UX Parity Phase 2c, 2026-07-28). Same shape as
  `post_debit_adjustment/6`: `direction: "CREDIT"` mirrors
  `post_prepaid_load/5`'s DR/CR (increases the balance);
  `direction: "DEBIT"` reverses it, same shape as `post_prepaid_spend/5`
  (decreases the balance).
  """
  def post_prepaid_adjustment(prepaid_account_id, amount, "CREDIT", posting_date, narrative, idempotency_key) do
    post(%{
      account_id:       prepaid_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "ADJUSTMENT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @cash_clearing,
      gl_account_cr:    @prepaid_liability,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end

  def post_prepaid_adjustment(prepaid_account_id, amount, "DEBIT", posting_date, narrative, idempotency_key) do
    post(%{
      account_id:       prepaid_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "ADJUSTMENT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @prepaid_liability,
      gl_account_cr:    @cash_clearing,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end

  @doc """
  Post a load into a Digital Wallet account (Way4 parity plan Phase 2,
  Phase W1, 2026-07-28) — same liability-direction shape as
  `post_debit_deposit/5`/`post_prepaid_load/5`, its own GL code (2006).
  """
  def post_wallet_load(wallet_account_id, amount, posting_date, channel, idempotency_key) do
    post(%{
      account_id:       wallet_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "DEPOSIT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @cash_clearing,
      gl_account_cr:    @wallet_liability,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Wallet account load: #{channel}"
    })
  end

  @doc """
  Post a withdrawal from a Digital Wallet account (Way4 parity plan
  Phase 2, Phase W1, 2026-07-28) — exact reverse of `post_wallet_load/5`.
  Unlike Debit's `post_debit_purchase/5` (which only makes an
  already-reserved journal entry permanent after clearing),
  `CMS.WalletWithdrawalCommand.withdraw/4` posts this in the SAME
  transaction as the atomic balance decrement — a wallet withdrawal has
  no separate authorization-then-clearing phases yet (no card/FAS path
  exists for Wallet in Phase W1), so there is nothing to reconcile
  later.
  """
  def post_wallet_withdrawal(wallet_account_id, amount, posting_date, narrative, idempotency_key) do
    post(%{
      account_id:       wallet_account_id,
      idempotency_key:  idempotency_key,
      # "PURCHASE" — reusing CMS.LedgerEntry's existing validated
      # transaction_code (its own list has no dedicated WITHDRAWAL code;
      # Debit/Prepaid's own money-leaving-the-account postings use the
      # same code for the same reason, not a literal card purchase).
      transaction_code: "PURCHASE",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    @wallet_liability,
      gl_account_cr:    @cash_clearing,
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end
end
