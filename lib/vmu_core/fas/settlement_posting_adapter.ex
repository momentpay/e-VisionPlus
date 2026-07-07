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
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.FAS.{AuthLookup, PendingHold}
  alias VmuCore.FAS.GL.{CardAccountCodes, VmuCoreGlAdapter}
  alias VmuCore.CMS.LedgerEntry
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

  defp do_confirm(auth, settled_amount, settled_date) do
    key = "settlement:#{auth.approval_code}:#{auth.rrn}"

    if already_posted?(key) do
      Logger.debug("[SettlementPostingAdapter] Already posted: #{key}")
      # Aggregate may still lag the ledger (e.g. a retried confirm after a
      # crash between posting and the TRAM sync) — idempotent re-sync
      sync_tram(auth, settled_amount, settled_date)
      :ok
    else
      Repo.transaction(fn ->
        post_ledger(auth, settled_amount, settled_date, key)
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
