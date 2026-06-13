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
  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator}
  alias VmuCore.LMS.CmsInterface

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "eod_date" => eod_date_str}}) do
    Repo.update_all(
      from(a in Account,
        where: a.account_id == ^account_id and a.account_status == "POSTING"),
      set: [account_status: "ACTIVE", updated_at: NaiveDateTime.utc_now()]
    )

    AccountStateCoordinator.refresh(account_id)

    eod_date = Date.from_iso8601!(eod_date_str)
    CmsInterface.trigger_points_calculation(eod_date)

    Logger.info("[EOD] FlushGL: account=#{account_id} date=#{eod_date_str} — unlocked, LMS triggered")
    :ok
  end
end
