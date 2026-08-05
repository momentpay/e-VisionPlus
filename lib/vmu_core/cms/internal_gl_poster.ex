defmodule VmuCore.CMS.InternalGlPoster do
  @moduledoc """
  Posts double-entry journal entries to cms_ledger_entries.
  Idempotency key prevents duplicate postings on job retry.

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

  require Logger
  alias VmuCore.{Repo, CMS.LedgerEntry}

  @doc """
  Post a journal entry. Returns {:ok, entry} or {:error, :duplicate} if
  the idempotency_key was already posted, or {:error, changeset} on validation failure.
  """
  def post(attrs) do
    cs = LedgerEntry.changeset(%LedgerEntry{}, attrs)

    case Repo.insert(cs, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, entry} ->
        # entry_id is a CLIENT-generated binary_id, so the returned struct
        # carries an id even when ON CONFLICT DO NOTHING skipped the insert —
        # the old `entry_id: nil` duplicate check never fired (latent bug
        # found 2026-07-05: duplicates reported {:ok, phantom_entry}).
        # Read back by key: same id ⇒ we inserted it; different ⇒ duplicate.
        persisted = Repo.get_by!(LedgerEntry, idempotency_key: entry.idempotency_key)

        if persisted.entry_id == entry.entry_id do
          Logger.debug("[GL] Posted #{entry.transaction_code} #{entry.dr_amount} key=#{entry.idempotency_key}")

          # GL Phase B/C — run the new posting engine.
          #
          # Phase B (shadow): `mirror/1` returns :ok whatever happens, so this
          # cannot change what the function returns or whether the posting
          # stands. Off unless
          # `config :vmu_core, VmuCore.Posting.Shadow, enabled: true`.
          #
          # Phase C (cutover): for a product in
          # `config :vmu_core, VmuCore.Posting.Cutover, products: [...]` the
          # engine is authoritative and a failure must abort. The legacy row is
          # deleted rather than left behind — twelve modules still read this
          # table, and a row the engine rejected must not be visible to them.
          case VmuCore.Posting.Shadow.mirror(attrs) do
            :ok ->
              {:ok, persisted}

            {:error, reason} ->
              Repo.delete!(persisted)

              Logger.error(
                "[GL] cutover posting REJECTED, legacy row rolled back. " <>
                  "key=#{entry.idempotency_key} reason=#{inspect(reason)}"
              )

              {:error, reason}
          end
        else
          {:error, :duplicate}
        end

      {:error, cs} ->
        {:error, cs}
    end
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
