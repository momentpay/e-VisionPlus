defmodule VmuCore.FAS.SettlementPostingAdapter do
  @moduledoc """
  Handles settlement confirmation from settlement_core (FAS-P4 4C + 4D).

  When settlement_core matches a dump record to a core_transaction and confirms
  it with vmu_core, this module:

  1. Posts a `PURCHASE` LedgerEntry row (double-entry: DR 1001 receivables /
     CR 2001 customer credit liability).
  2. Sets `fas_pending_holds.cleared_at` so the hold exits the aging view.

  Both operations are wrapped in a transaction and guarded by an idempotency key
  (`"settlement:<approval_code>:<rrn>"`), so re-running for the same confirmation
  is safe.

  Note on OTB: The ASC already decremented open_to_buy at auth time. At settlement
  the debit is confirmed (not reversed), so OTB stays correctly reduced — no
  `credit_open_to_buy` call is made. OTB is only restored when the customer pays.

  ## Debit (Way4 parity plan Phase 1 item 4, D4)

  `auth.account_id` may be a `CMS.DebitAccount.debit_account_id` instead
  of a `CMS.Account.account_id` — found live: this whole confirmation
  path was 100% credit-shaped (`post_ledger/3` hardcoded credit GL codes,
  `post_bucket/4`'s `PurchasePosting.post/1` does `Repo.get(Account,
  ...)`, always `nil` for a debit id, which would roll back every debit
  settlement confirmation). `do_confirm/3` now branches on `DebitAuthorization.
  debit_account?/1` first. Debit's `available_balance` was already
  decremented in real time at authorization (no OTB-then-settle two-phase
  model for this product) — settlement only needs to post the permanent
  GL entry and clear the hold, not touch a balance bucket.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.{AuthLookup, PendingHold}
  alias VmuCore.FAS.GL.{CardAccountCodes, VmuCoreGlAdapter}
  alias VmuCore.CMS.{LedgerEntry, PurchasePosting, DebitAuthorization, InternalGlPoster}
  alias WalletGl.GlPostingRecord
  alias WalletSharedKernel.Money

  @doc """
  Confirm settlement for a batch of matched authorization records.

  Each item must be a map with:
    - `:approval_code`  — DE38 approval code from the dump record
    - `:rrn`            — retrieval reference number
    - `:settled_amount` — Decimal; actual settled amount (may differ from auth amount)
    - `:settled_date`   — Date; settlement / dump date

  Returns `%{confirmed: n, not_found: n, errors: n}`.
  """
  @spec confirm_batch([map()]) :: map()
  def confirm_batch(items) when is_list(items) do
    Enum.reduce(items, %{confirmed: 0, not_found: 0, errors: 0}, fn item, acc ->
      case confirm_one(item) do
        :ok          -> Map.update!(acc, :confirmed,  & &1 + 1)
        :not_found   -> Map.update!(acc, :not_found,  & &1 + 1)
        {:error, _}  -> Map.update!(acc, :errors,     & &1 + 1)
      end
    end)
  end

  @doc "Confirm settlement for a single authorization. Idempotent."
  @spec confirm_one(map()) :: :ok | :not_found | {:error, term()}
  def confirm_one(%{approval_code: approval_code, rrn: rrn,
                    settled_amount: settled_amount, settled_date: settled_date}) do
    auth = AuthLookup.by_approval_code_and_rrn(approval_code, rrn)

    if is_nil(auth) do
      Logger.warning("[SettlementPostingAdapter] Auth not found: " <>
                     "approval_code=#{approval_code} rrn=#{rrn}")
      :not_found
    else
      do_confirm(auth, settled_amount, settled_date)
    end
  end

  # Way4 parity plan Phase 1 item 4 (Debit, D4) — everything below this
  # point was unconditionally credit-shaped; `auth.account_id` may now be
  # a `CMS.DebitAccount.debit_account_id`, which has no balance-bucket or
  # credit-receivable concept at all. Dispatch first, same convention as
  # `FAS.Authorization.run_authorization/1`'s product_type branch.
  defp do_confirm(auth, settled_amount, settled_date) do
    if DebitAuthorization.debit_account?(auth.account_id) do
      do_confirm_debit(auth, settled_amount, settled_date)
    else
      do_confirm_credit(auth, settled_amount, settled_date)
    end
  end

  defp do_confirm_credit(auth, settled_amount, settled_date) do
    key = "settlement:#{auth.approval_code}:#{auth.rrn}"

    if already_posted?(key) do
      Logger.debug("[SettlementPostingAdapter] Already posted: #{key}")
      # Aggregate may still lag the ledger (e.g. a retried confirm after a
      # crash between posting and the TRAM sync) — idempotent re-sync.
      # post_bucket/4 is separately idempotent on the same key, so a retry
      # here is safe even if the very first attempt posted the GL entry
      # but crashed before the bucket increment. Best-effort here (no open
      # transaction to roll back to) — logged, not raised; the
      # transactional first-attempt path below is where a real failure
      # blocks the confirmation.
      case post_bucket(auth, settled_amount, settled_date, key) do
        :ok -> :ok
        {:error, reason} ->
          Logger.warning("[SettlementPostingAdapter] bucket re-sync failed for #{key}: #{inspect(reason)}")
      end

      sync_tram(auth, settled_amount, settled_date)
      :ok
    else
      Repo.transaction(fn ->
        post_ledger(auth, settled_amount, settled_date, key)

        # FR-067 — found live, 2026-07-24: this posted a real GL entry but
        # never touched the account's outstanding balance anywhere. Atomic
        # with the GL post (same transaction) — both commit or both roll
        # back. See VmuCore.CMS.PurchasePosting.
        case post_bucket(auth, settled_amount, settled_date, key) do
          :ok -> :ok
          {:error, reason} -> Repo.rollback({:bucket_post_failed, reason})
        end

        clear_hold(auth)
      end)
      |> case do
        {:ok, _} ->
          sync_tram(auth, settled_amount, settled_date)
          :ok

        {:error, reason} ->
          Logger.error("[SettlementPostingAdapter] Failed #{key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # Debit has no balance-bucket step at all — `available_balance` was
  # already decremented in real time at authorization (`CMS.
  # DebitAuthorization.authorize/2`), unlike credit's OTB-then-settle
  # two-phase model. Settlement here only needs to (1) make the
  # already-reserved journal entry permanent and (2) clear the hold.
  defp do_confirm_debit(auth, settled_amount, settled_date) do
    key = "settlement:#{auth.approval_code}:#{auth.rrn}"

    if already_posted?(key) do
      Logger.debug("[SettlementPostingAdapter] Already posted (debit): #{key}")
      sync_tram(auth, settled_amount, settled_date)
      :ok
    else
      Repo.transaction(fn ->
        case InternalGlPoster.post_debit_purchase(auth.account_id, settled_amount, settled_date, auth.currency, key) do
          {:ok, _entry} -> :ok
          {:error, :duplicate} -> :ok
          {:error, reason} -> Repo.rollback({:gl_post_failed, reason})
        end

        clear_hold(auth)
      end)
      |> case do
        {:ok, _} ->
          sync_tram(auth, settled_amount, settled_date)
          :ok

        {:error, reason} ->
          Logger.error("[SettlementPostingAdapter] Failed (debit) #{key}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  # TRAM aggregate sync (TRAM-P3 addendum) — real-time counterpart of the
  # posting cycle's ledger-key check. Fail-safe inside AuthConsumer; runs
  # after the posting transaction commits, never inside it.
  defp sync_tram(auth, settled_amount, settled_date) do
    VmuCore.TRAMS.AuthConsumer.record_settlement_confirmation(
      auth, settled_amount, settled_date)
  end

  defp already_posted?(key) do
    Repo.exists?(from e in LedgerEntry, where: e.idempotency_key == ^key)
  end

  # FR-067 — the real outstanding-balance side of a purchase, previously
  # missing entirely. "atm" channel = cash advance (same convention
  # TRAMS.AuthConsumer.transaction_type/1 already uses); everything else
  # defaults to a retail purchase.
  defp post_bucket(auth, amount, posting_date, key) do
    bucket_field = if auth.channel == "atm", do: "cash_balance", else: "retail_balance"

    case PurchasePosting.post(%{
           account_id: auth.account_id,
           amount: amount,
           bucket_field: bucket_field,
           transaction_date: posting_date,
           idempotency_key: key
         }) do
      {:ok, _allocation} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp post_ledger(auth, amount, posting_date, key) do
    currency     = auth.currency || "AED"
    minor_units  = amount |> Decimal.mult(100) |> Decimal.round(0) |> Decimal.to_integer()
    money        = Money.new(minor_units, currency)
    narrative    = "Settlement: approval=#{auth.approval_code} rrn=#{auth.rrn}"

    entries = [
      %{account_code: CardAccountCodes.card_receivables(), description: narrative,
        debit_amount: money, credit_amount: nil, cost_center: nil, reference: key},
      %{account_code: CardAccountCodes.credit_liability(), description: narrative,
        debit_amount: nil, credit_amount: money, cost_center: nil, reference: key}
    ]

    {:ok, record} = GlPostingRecord.new(key, posting_date, entries, "vmu_core_gl",
                      correlation_id: auth.account_id)

    case VmuCoreGlAdapter.post_entry(record, nil) do
      {:ok, _txn_id}   -> :ok
      {:error, reason} -> Repo.rollback({:gl_post_failed, reason})
    end
  end

  defp clear_hold(auth) do
    hold =
      Repo.one(
        from h in PendingHold,
          where: h.fas_authorization_id == ^auth.id and is_nil(h.cleared_at),
          lock: "FOR UPDATE"
      )

    if hold do
      hold
      |> PendingHold.clear_changeset(DateTime.utc_now())
      |> Repo.update!()
    end
  end
end
