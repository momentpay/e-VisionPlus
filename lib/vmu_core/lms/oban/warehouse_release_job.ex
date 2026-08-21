defmodule VmuCore.LMS.Oban.WarehouseReleaseJob do
  @moduledoc """
  Daily Oban job — promotes `WAREHOUSE`-state ledger entries to `ACTIVE`
  once the owning scheme's `warehouse_days` have elapsed since posting.

  Closes the gap `LMS_Gap_Implementation_Tracker.md`'s LMS-P1 explicitly
  flagged: `PointsEngine.post_earned_points/7` already posts `WAREHOUSE`
  for a scheme with `warehouse_days > 0` (and, correctly, does NOT
  increment `open_to_redeem` for those — see `update_account_balance/3`),
  but nothing ever promoted them onward. Every scheme observed in this
  codebase defaults `warehouse_days: 0` (immediate `ACTIVE`), so this
  never affected the common path — but a scheme that actually configures
  warehousing had its points earn permanently un-redeemable before this.

  `points_balance`/`lifetime_earned` were already incremented at earn
  time regardless of warehouse state (see `update_account_balance/3`'s
  second clause) — release only needs to add the released amount to
  `open_to_redeem`, mirroring exactly what an immediate `ACTIVE` earn
  already does.

  Cron: daily (see `config/config.exs`).
  """

  use Oban.Worker, queue: :lms, max_attempts: 3

  require Logger
  import Ecto.Query
  alias VmuCore.Repo
  alias VmuCore.LMS.{Account, PointsLedger, Scheme}

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()
    Logger.info("[LMS/WarehouseRelease] Processing releases as of #{today}")

    entries =
      from(l in PointsLedger,
        join: s in Scheme, on: s.id == l.scheme_id,
        where: l.warehouse_state == "WAREHOUSE" and l.points_amount > 0
           and s.warehouse_days > 0
           and fragment("? + ?", l.posting_date, s.warehouse_days) <= ^today,
        select: %{id: l.id, lms_account_id: l.lms_account_id, points_amount: l.points_amount}
      )
      |> Repo.all()

    Logger.info("[LMS/WarehouseRelease] #{length(entries)} entries to release")

    Enum.each(entries, &release_entry/1)
    :ok
  end

  defp release_entry(%{id: id, lms_account_id: lms_account_id, points_amount: points}) do
    Repo.transaction(fn ->
      Repo.update_all(
        from(l in PointsLedger, where: l.id == ^id),
        set: [warehouse_state: "ACTIVE"]
      )

      Repo.update_all(
        from(a in Account, where: a.id == ^lms_account_id),
        inc: [open_to_redeem: points]
      )
    end)
  end
end
