defmodule VmuCore.CMS.InternalGlPoster do
  @moduledoc """
  Posts double-entry journal entries to cms_ledger_entries.
  Idempotency key prevents duplicate postings on job retry.

  GL account code conventions (chart of accounts):
    1001 — Cardholder retail receivable
    1002 — Cardholder cash advance receivable
    1003 — Accrued interest receivable
    1004 — Fee receivable
    2001 — Interest income
    2002 — Fee income
    3001 — Cardholder payment liability
    4001 — Interchange income

  Debit (Way4 parity plan Phase 1 item 4) posts in the OPPOSITE direction
  from every code above — a debit account's balance is a deposit
  *liability* (amount the bank owes the depositor), not a receivable
  asset, so a deposit increases a liability account, not a receivable:
    1006 — Bank cash/clearing account (asset)
    5001 — Debit deposit liability

  Prepaid (Way4 parity plan Phase 1 item 5) is liability-direction too,
  but its own distinct code — a different product for chart-of-accounts
  purposes even though the mechanism (stored value the bank owes the
  cardholder) is the same shape as Debit's:
    5002 — Prepaid stored-value liability
  """

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
          {:ok, persisted}
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
      gl_account_dr:    "1003",
      gl_account_cr:    "2001",
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
      gl_account_dr:    "1004",
      gl_account_cr:    "2002",
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
      gl_account_dr:    "3001",
      gl_account_cr:    "1001",
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
      gl_account_dr:    "1006",
      gl_account_cr:    "5001",
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        "Debit account funding: #{channel}"
    })
  end

  @doc """
  Post a cleared purchase against a debit account (Way4 parity plan
  Phase 1 item 4, D4) — the exact reverse direction of
  `post_debit_deposit/5`: the deposit liability (5001) decreases (DR),
  the offsetting credit is the bank's own cash position (1006) paying
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
      gl_account_dr:    "5001",
      gl_account_cr:    "1006",
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
      gl_account_dr:    "1006",
      gl_account_cr:    "5001",
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
      gl_account_dr:    "5001",
      gl_account_cr:    "1006",
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end

  @doc """
  Post a load into a prepaid account (Way4 parity plan Phase 1 item 5,
  P1) — same liability-direction shape as `post_debit_deposit/5`, its
  own GL code (5002, not 5001 — a different product).
  """
  def post_prepaid_load(prepaid_account_id, amount, posting_date, channel, idempotency_key) do
    post(%{
      account_id:       prepaid_account_id,
      idempotency_key:  idempotency_key,
      transaction_code: "DEPOSIT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    "1006",
      gl_account_cr:    "5002",
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
      gl_account_dr:    "5002",
      gl_account_cr:    "1006",
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
      gl_account_dr:    "1006",
      gl_account_cr:    "5002",
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
      gl_account_dr:    "5002",
      gl_account_cr:    "1006",
      posting_date:     posting_date,
      value_date:       posting_date,
      narrative:        narrative
    })
  end
end
