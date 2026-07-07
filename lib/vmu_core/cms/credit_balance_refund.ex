defmodule VmuCore.CMS.CreditBalanceRefund do
  @moduledoc """
  Credit-balance (overpayment) refunds (CMS-G4.1, FR-CMS-024).

  ## Where a credit balance lives

  `PaymentIntake` distributes only up to what the buckets hold — the
  unallocated `remainder` of an overpayment is recorded on the
  `cms_payments` register row, NOT pushed into a bucket (buckets never go
  negative). The customer's credit balance is therefore:

      Σ remainder of POSTED payments  −  Σ refunds already paid out

  (REVERSED payments drop out of the sum automatically — a bounced
  overpayment takes its remainder with it.)

  ## Refund

  4-eyes at the CMS-command level (same convention as `FeeWaiver` /
  `FinancialAdjustment` — ADR-A4: the UI layer validates the checker via
  `ASM.Authz.validate_checker/4` before calling): operator ≠ supervisor
  enforced here, amount capped at the available credit balance. GL:
  ADJUSTMENT, DR 1001 Card Receivables / CR 9001 clearing (money going back
  out), idempotency key `"refund:<account>:<reference>"`.

  No bucket movement and no OTB change — the credit balance never entered
  either.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.Payment, CMS.LedgerEntry, CMS.InternalGlPoster}
  alias Decimal, as: D

  @doc "Current refundable credit balance for the account."
  @spec credit_balance(Ecto.UUID.t()) :: Decimal.t()
  def credit_balance(account_id) do
    remainders =
      Repo.one(
        from p in Payment,
          where: p.account_id == ^account_id and p.status == "POSTED",
          select: coalesce(sum(p.remainder), 0)
      ) || D.new(0)

    D.sub(remainders, total_refunded(account_id))
  end

  @doc "Sum of refunds already paid out (from the ledger's refund keys)."
  @spec total_refunded(Ecto.UUID.t()) :: Decimal.t()
  def total_refunded(account_id) do
    Repo.one(
      from e in LedgerEntry,
        where: e.account_id == ^account_id
           and like(e.idempotency_key, ^"refund:#{account_id}:%"),
        select: coalesce(sum(e.dr_amount), 0)
    ) || D.new(0)
  end

  @doc """
  Refund `amount` of the account's credit balance.

  Opts (keyword): `:reference` (required, unique per refund), `:operator_id`,
  `:supervisor_id` (must differ — 4-eyes), `:narrative`.

  Returns `{:ok, ledger_entry}` or `{:error, reason}`.
  """
  @spec refund(Ecto.UUID.t(), Decimal.t(), keyword()) ::
          {:ok, LedgerEntry.t()} | {:error, term()}
  def refund(account_id, amount, opts) do
    reference     = Keyword.fetch!(opts, :reference)
    operator_id   = Keyword.get(opts, :operator_id, "SYSTEM")
    supervisor_id = Keyword.get(opts, :supervisor_id)

    cond do
      D.compare(amount, 0) != :gt ->
        {:error, :invalid_amount}

      is_nil(supervisor_id) or supervisor_id == operator_id ->
        {:error, :operator_and_supervisor_must_differ}

      is_nil(Repo.get(Account, account_id)) ->
        {:error, :account_not_found}

      true ->
        available = credit_balance(account_id)

        if D.compare(amount, available) == :gt do
          {:error, {:exceeds_credit_balance, available}}
        else
          post_refund(account_id, amount, reference, operator_id, supervisor_id, opts)
        end
    end
  end

  @doc "Accounts with a positive credit balance — the refund ops queue."
  @spec refund_candidates(non_neg_integer()) :: [%{account_id: Ecto.UUID.t(), credit_balance: Decimal.t()}]
  def refund_candidates(limit \\ 50) do
    # Candidate = any account holding POSTED remainders; exact balance is
    # then netted against refunds per account
    Repo.all(
      from p in Payment,
        where: p.status == "POSTED" and not is_nil(p.account_id) and p.remainder > 0,
        group_by: p.account_id,
        select: p.account_id,
        limit: ^limit
    )
    |> Enum.map(fn account_id ->
      %{account_id: account_id, credit_balance: credit_balance(account_id)}
    end)
    |> Enum.filter(fn %{credit_balance: bal} -> D.compare(bal, 0) == :gt end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp post_refund(account_id, amount, reference, operator_id, supervisor_id, opts) do
    case InternalGlPoster.post(%{
           account_id:       account_id,
           idempotency_key:  "refund:#{account_id}:#{reference}",
           transaction_code: "ADJUSTMENT",
           dr_amount:        amount,
           cr_amount:        amount,
           gl_account_dr:    "1001",
           gl_account_cr:    "9001",
           posting_date:     Date.utc_today(),
           value_date:       Date.utc_today(),
           narrative:        Keyword.get(opts, :narrative,
                               "Credit balance refund ref=#{reference} " <>
                               "op=#{operator_id} sup=#{supervisor_id}"),
           source_ref:       reference
         }) do
      {:ok, entry} ->
        Logger.info("[CreditBalanceRefund] Refunded #{amount} account=#{account_id} " <>
                    "ref=#{reference} op=#{operator_id}/#{supervisor_id}")
        {:ok, entry}

      {:error, :duplicate} ->
        {:error, :duplicate_refund}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
