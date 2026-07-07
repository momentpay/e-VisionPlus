defmodule VmuCore.CMS.PaymentReversal do
  @moduledoc """
  Bounced/returned payment processing (CMS-G2.1, FR-CMS-064).

  When a payment's funding fails after application (direct-debit return,
  gateway chargeback of the funding leg):

  1. **Exact bucket re-debit** — the register row's `postings` breakdown is
     replayed in reverse: each bucket gets back precisely what the payment
     took, no reverse-hierarchy guessing.
  2. **GL reversal** — `REVERSAL` entry keyed `"payment_reversal:<ref>"`,
     DR 1001 / CR 9001 for the full received amount (mirror of the PAYMENT
     entry).
  3. **Returned-payment fee** — the LOGO's `returned_payment_fee` (if > 0)
     posts as a FEE entry (DR 2001 / CR 4001) and lands in `unpaid_fees`.
  4. **OTB re-debit** — the allocated amount is taken back out of
     open-to-buy (negative `credit_open_to_buy`).
  5. Register row → REVERSED with reason + timestamp.

  Delinquency: reversal does NOT itself re-age the account — the nightly
  EOD aging job re-derives the bucket from the restored balances on its next
  run, which also covers "payment cleared past-due, then bounced". A same-day
  synchronous re-age is a future refinement, flagged in the tracker.

  Idempotent: a second `reverse/2` for the same reference returns
  `{:error, :already_reversed}`.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Payment, CMS.Account, CMS.BalanceBucket,
                 CMS.InternalGlPoster, CMS.AccountStateCoordinator}
  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  @doc """
  Reverse a POSTED payment by its external reference.

  Returns `{:ok, %{payment: row, fee_assessed: Decimal | nil}}` or
  `{:error, :not_found | :already_reversed | {:not_reversible, status} | term}`.
  """
  @spec reverse(String.t(), String.t()) :: {:ok, map()} | {:error, term()}
  def reverse(reference, reason) do
    case Repo.get_by(Payment, reference: reference) do
      nil ->
        {:error, :not_found}

      %Payment{status: "REVERSED"} ->
        {:error, :already_reversed}

      %Payment{status: "POSTED"} = payment ->
        do_reverse(payment, reason)

      %Payment{status: status} ->
        {:error, {:not_reversible, status}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_reverse(payment, reason) do
    account = Repo.get!(Account, payment.account_id)
    bucket  = latest_bucket(account.account_id)
    fee     = returned_payment_fee(account)

    result =
      Repo.transaction(fn ->
        redebit_buckets!(bucket, payment.postings)
        post_reversal_ledger!(payment, account)
        fee_assessed = maybe_assess_fee!(payment, account, bucket, fee)

        updated =
          payment
          |> Payment.changeset(%{
            status: "REVERSED",
            reversal_reason: String.slice(reason, 0, 100),
            reversed_at: DateTime.utc_now() |> DateTime.truncate(:second)
          })
          |> Repo.update!()

        %{payment: updated, fee_assessed: fee_assessed}
      end)

    case result do
      {:ok, outcome} ->
        # OTB re-debit outside the DB transaction (ASC is in-memory).
        # credit_otb is a plain Decimal.add, so a negative delta debits.
        if payment.allocated && D.compare(payment.allocated, 0) == :gt do
          AccountStateCoordinator.credit_open_to_buy(
            account.account_id, D.negate(payment.allocated))
        end

        Logger.warning("[PaymentReversal] Reversed #{payment.reference} " <>
                       "account=#{account.account_id} amount=#{payment.amount} " <>
                       "fee=#{inspect(outcome.fee_assessed)} reason=#{reason} — " <>
                       "delinquency re-ages at next EOD")

        {:ok, outcome}

      {:error, tx_reason} ->
        Logger.error("[PaymentReversal] Failed #{payment.reference}: #{inspect(tx_reason)}")
        {:error, tx_reason}
    end
  end

  # Replay the stored distribution in reverse — each bucket gets back
  # exactly what the payment took
  defp redebit_buckets!(bucket, postings) do
    incs =
      postings
      |> Enum.map(fn {field, amount} ->
        {String.to_existing_atom(field), D.new(amount)}
      end)
      |> Enum.reject(fn {_f, amt} -> D.compare(amt, 0) != :gt end)

    if incs != [] do
      {1, _} =
        Repo.update_all(
          from(b in BalanceBucket, where: b.bucket_id == ^bucket.bucket_id),
          inc: incs
        )
    end

    :ok
  end

  defp post_reversal_ledger!(payment, account) do
    case InternalGlPoster.post(%{
           account_id:       account.account_id,
           idempotency_key:  "payment_reversal:#{payment.reference}",
           transaction_code: "REVERSAL",
           dr_amount:        payment.amount,
           cr_amount:        payment.amount,
           gl_account_dr:    "1001",
           gl_account_cr:    "9001",
           posting_date:     Date.utc_today(),
           value_date:       Date.utc_today(),
           narrative:        "Returned payment ref=#{payment.reference}",
           source_ref:       payment.reference
         }) do
      {:ok, _} -> :ok
      {:error, :duplicate} -> :ok
      {:error, reason} -> Repo.rollback({:gl_reversal_failed, reason})
    end
  end

  defp maybe_assess_fee!(_payment, _account, _bucket, nil), do: nil

  defp maybe_assess_fee!(payment, account, bucket, fee) do
    case InternalGlPoster.post(%{
           account_id:       account.account_id,
           idempotency_key:  "payment_reversal_fee:#{payment.reference}",
           transaction_code: "FEE",
           dr_amount:        fee,
           cr_amount:        fee,
           gl_account_dr:    "2001",
           gl_account_cr:    "4001",
           posting_date:     Date.utc_today(),
           value_date:       Date.utc_today(),
           narrative:        "Returned payment fee ref=#{payment.reference}",
           source_ref:       payment.reference
         }) do
      {:ok, _} ->
        Repo.update_all(
          from(b in BalanceBucket, where: b.bucket_id == ^bucket.bucket_id),
          inc: [unpaid_fees: fee]
        )

        fee

      {:error, :duplicate} ->
        fee

      {:error, reason} ->
        Repo.rollback({:fee_post_failed, reason})
    end
  end

  defp returned_payment_fee(account) do
    case ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id,
                             account.block_id || "", :returned_payment_fee) do
      {:ok, %D{} = fee} ->
        if D.compare(fee, 0) == :gt, do: fee, else: nil

      _ ->
        nil
    end
  end

  defp latest_bucket(account_id) do
    Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1
    )
  end
end
