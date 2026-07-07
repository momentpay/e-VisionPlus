defmodule VmuCore.CMS.ChargeOffRecovery do
  @moduledoc """
  Post-charge-off recovery accounting (CMS-G4.3, FR-CMS-014).

  After `COL.WriteOffProcessor.write_off/1` (status → WRITTEN_OFF, balance
  moved to the charged-off GL bucket), money that later arrives for the
  account is a **recovery**, not a payment:

  - No bucket distribution (buckets were written off) and no OTB restore
    (the account declines all authorizations permanently).
  - GL goes to recovery income via COL's existing `post_recovery/3`
    (DR 1000 cash / CR 6001 recovery income, key `"RECOVERY-<ref>"`) — this
    module validates and wraps it, keeping one GL convention.
  - Interest/fee suppression (FR-CMS-014) holds **structurally**: the EOD
    scheduler only selects ACTIVE/DELINQUENT accounts, so WRITTEN_OFF
    accounts never enter the accrual/fee chain.

  `PaymentIntake.receive_payment/1` routes WRITTEN_OFF accounts here
  automatically, so a recovery arriving through a normal payment channel
  cannot corrupt buckets/OTB.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.LedgerEntry}
  alias VmuCore.COL.WriteOffProcessor
  alias Decimal, as: D

  @doc """
  Record a recovery receipt against a WRITTEN_OFF account.

  Returns `{:ok, %{entry: ledger_entry, total_recovered: Decimal}}` or
  `{:error, reason}`.
  """
  @spec record_recovery(Ecto.UUID.t(), Decimal.t(), String.t()) ::
          {:ok, map()} | {:error, term()}
  def record_recovery(account_id, amount, reference) do
    cond do
      D.compare(amount, 0) != :gt ->
        {:error, :invalid_amount}

      is_nil(reference) or reference == "" ->
        {:error, :reference_required}

      true ->
        case Repo.get(Account, account_id) do
          nil ->
            {:error, :account_not_found}

          %Account{account_status: "WRITTEN_OFF"} ->
            post(account_id, amount, reference)

          %Account{account_status: status} ->
            {:error, {:not_written_off, status}}
        end
    end
  end

  @doc "Total recovered against a charged-off account (ledger RECOVERY keys)."
  @spec total_recovered(Ecto.UUID.t()) :: Decimal.t()
  def total_recovered(account_id) do
    Repo.one(
      from e in LedgerEntry,
        where: e.account_id == ^account_id
           and like(e.idempotency_key, "RECOVERY-%"),
        select: coalesce(sum(e.dr_amount), 0)
    ) || D.new(0)
  end

  defp post(account_id, amount, reference) do
    case WriteOffProcessor.post_recovery(account_id, amount, reference) do
      {:ok, entry} ->
        total = total_recovered(account_id)

        Logger.info("[ChargeOffRecovery] Recovered #{amount} account=#{account_id} " <>
                    "ref=#{reference} total_recovered=#{total}")

        {:ok, %{entry: entry, total_recovered: total}}

      {:error, :duplicate} ->
        {:error, :duplicate_recovery}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
