defmodule VmuCore.CMS.Oban.OtbReconciliationSweepJob do
  @moduledoc """
  Periodic OTB write-back sweep.

  `AccountStateCoordinator.load_state/1` already reconstructs
  `open_to_buy`/`cash_open_to_buy` from durable holds at boot (via
  `VmuCore.CMS.OtbReconciliation`) — that's the actual crash-durability fix.
  This job exists for a separate reason: several places read
  `cms_accounts.open_to_buy` directly via a plain `Ecto.Query`, bypassing the
  live coordinator entirely (e.g. the operator console,
  `VmuCoreWeb.OperatorConsolePage`). Nothing ever wrote the reconstructed
  value back into that column, so anyone reading it directly saw an
  increasingly stale number forever, and
  `COL.WriteOffProcessor.write_off/1` derives the GL write-off amount from
  that same stale column — a real accounting understatement, not just a
  display issue.

  Runs every 10 minutes (see the cron entry in `config/config.exs`),
  re-running the same `OtbReconciliation.reconstruct/1` every
  `AccountStateCoordinator.load_state/1` uses — one shared implementation,
  so the stored column and "what the coordinator would reconstruct if it
  restarted right now" can never disagree.

  Deliberately off any authorization hot path (this repo's own CLAUDE.md,
  "What NOT To Do": no DB round-trips inside a GenServer call on the
  authorization hot path) — this is a scheduled batch job, the same idiom
  `TRAMS.Oban.AuthExpirySweepJob` already uses for a related sweep.

  `account_status not in ["CLOSED", "WRITTEN_OFF"]` is an **exclusion list,
  not an inclusion list**, on purpose:
    - `AccountClosure` requires zero active holds before an account may
      close, so reconstruction there would (harmlessly) yield the full
      limit anyway — but CLOSED accounts are excluded regardless, since
      there's nothing left to reconcile for them.
    - `COL.WriteOffProcessor` writes off *delinquent* accounts that still
      carry real active holds — reconstruction would yield a real, nonzero
      value that must NOT overwrite the deliberately-zeroed `open_to_buy`
      a write-off sets. WRITTEN_OFF is excluded for exactly this reason.
    - `DELINQUENT`/`BLOCKED`/`SUSPENDED`/`POSTING` accounts stay **included**
      — that's precisely the population the write-off GL-accuracy fix
      depends on; an inclusion list keyed on "ACTIVE" would have missed them.
  """

  use Oban.Worker, queue: :default, max_attempts: 3, unique: [period: 300]

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, OtbReconciliation}

  @batch_limit 500
  @excluded_statuses ["CLOSED", "WRITTEN_OFF"]

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    stats =
      accounts_to_reconcile()
      |> Enum.reduce(%{updated: 0, errors: 0}, fn account, acc ->
        reconcile_one(account, acc)
      end)

    Logger.info("[CMS.OtbReconciliationSweep] updated=#{stats.updated} errors=#{stats.errors}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp accounts_to_reconcile do
    Repo.all(
      from a in Account,
        where: a.account_status not in ^@excluded_statuses,
        order_by: [asc: a.account_id],
        limit: @batch_limit
    )
  end

  defp reconcile_one(account, acc) do
    otb = OtbReconciliation.reconstruct(account)

    {count, _} =
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account.account_id),
        set: [
          open_to_buy:      otb.open_to_buy,
          cash_open_to_buy: otb.cash_open_to_buy,
          updated_at:       NaiveDateTime.utc_now()
        ]
      )

    Map.update!(acc, :updated, &(&1 + count))
  rescue
    e ->
      Logger.error("[CMS.OtbReconciliationSweep] account #{account.account_id} crashed: " <>
                   Exception.message(e))
      Map.update!(acc, :errors, &(&1 + 1))
  end
end
