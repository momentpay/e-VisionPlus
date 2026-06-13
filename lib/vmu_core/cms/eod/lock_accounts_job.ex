defmodule VmuCore.CMS.EOD.LockAccountsJob do
  @moduledoc """
  EOD Step 1 — Mark all accounts with today's cycle_code as posting_in_progress.

  Accounts in this state will decline new authorizations via AccountStateCoordinator
  until FlushGlJob unlocks them. This prevents mid-EOD OTB drift.

  Enqueues AccrueInterestJob for each locked account upon completion.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"eod_date" => eod_date_str, "cycle_code" => cycle_code}}) do
    eod_date = Date.from_iso8601!(eod_date_str)

    Logger.info("[EOD] LockAccounts: cycle_code=#{cycle_code} date=#{eod_date}")

    accounts_to_lock =
      Repo.all(
        from a in Account,
          where: a.cycle_code == ^cycle_code
            and a.account_status == "ACTIVE",
          select: a.account_id
      )

    Repo.update_all(
      from(a in Account,
        where: a.account_id in ^accounts_to_lock),
      set: [account_status: "POSTING", updated_at: NaiveDateTime.utc_now()]
    )

    # Notify in-memory coordinators of status change
    Enum.each(accounts_to_lock, &AccountStateCoordinator.refresh/1)

    # Enqueue next EOD step for each account
    jobs =
      Enum.map(accounts_to_lock, fn account_id ->
        %{account_id: to_string(account_id), eod_date: eod_date_str}
        |> VmuCore.CMS.EOD.AccrueInterestJob.new()
      end)

    Oban.insert_all(jobs)

    Logger.info("[EOD] LockAccounts: locked #{length(accounts_to_lock)} accounts")
    :ok
  end
end
