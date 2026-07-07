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
end
