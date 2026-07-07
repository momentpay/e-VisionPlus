defmodule VmuCore.CMS.EOD.FlushGlJob do
  @moduledoc """
  EOD Step 5 — Unlock the account and flush the cycle's GL entries.

  Actions:
    1. Set account_status back to ACTIVE (was POSTING during EOD lock).
    2. Refresh AccountStateCoordinator so it picks up the new OTB/balance.
    3. Emit a GL extract event so the core banking adapter can pick up new entries.

  This is the final step in the sequential EOD chain for one account.
  """

  use Oban.Worker, queue: :eod, max_attempts: 5, unique: [period: 86_400]

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator, CMS.FeeEngine, CMS.CoreBankingAdapter}
  alias VmuCore.LMS.CmsInterface

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)

    # Load account for fee assessment and logging
    account = Repo.get!(Account, account_id)

    # ── Annual fee assessment ────────────────────────────────────────────────
    # Check if today is this account's open-date anniversary and post annual fee
    account_map = %{
      sys_id:    account.sys_id,
      bank_id:   account.bank_id,
      logo_id:   account.logo_id,
      block_id:  account.block_id,
      open_date: account.open_date,
      open_to_buy: account.open_to_buy
    }
    FeeEngine.assess_annual_fee(account_id, account_map, eod_date)

    # ── Unlock account (POSTING → ACTIVE) ───────────────────────────────────
    Repo.update_all(
      from(a in Account,
        where: a.account_id == ^account_id and a.account_status == "POSTING"),
      set: [account_status: "ACTIVE", updated_at: NaiveDateTime.utc_now()]
    )

    AccountStateCoordinator.refresh(account_id)

    CmsInterface.trigger_points_calculation(eod_date)

    # ── GL extract to core banking (3J) ──────────────────────────────────────
    case CoreBankingAdapter.extract_for(account_id, eod_date) do
      {:ok, %{count: n, total_amount: total}} ->
        Logger.info("[EOD] FlushGL: account=#{account_id} date=#{eod_date_str} — unlocked, LMS triggered, GL extracted #{n} entries (total #{total})")
      {:error, reason} ->
        Logger.error("[EOD] FlushGL: GL extract FAILED account=#{account_id} date=#{eod_date_str}: #{inspect(reason)}")
        # Do not fail the EOD job — log and continue; extract can be retried via extract_all/1
    end

    :ok
  end
end
