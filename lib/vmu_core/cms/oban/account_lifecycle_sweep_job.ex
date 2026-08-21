defmodule VmuCore.CMS.Oban.AccountLifecycleSweepJob do
  @moduledoc """
  Nightly account lifecycle sweep (CMS-G3) — cron 05:00, before the 06:00
  autopay run:

  1. **Pending closures** (`AccountClosure.finalize_pending/0`) — closes any
     closure-requested account whose blockers (balance / holds / disputes)
     have since cleared.
  2. **Dormancy flag** (FR-CMS-015/059) — ACTIVE accounts with no activity
     (no ledger posting, no authorization, no payment) within
     `:cms_dormancy_days` (default 365) get `dormant_since` stamped +
     `dormancy_flagged` event. Inactivity **fee** assessment is deliberately
     out of scope until an `inactivity_fee` LOGO parameter is defined
     (CMS-G4 candidate).
  3. **Dormancy clear** — flagged accounts with any recent activity get the
     flag removed + `dormancy_cleared` event.
  4. **Promo expiry cleanup** (CMS-G4.2, FR-CMS-040) — the *pricing* revert
     is already dynamic (`PlanSegment.effective_apr/1` returns the standard
     APR the day after `promo_expiry_date`, so accrual re-prices with zero
     orchestration); this pass clears the stale promo fields on expired
     PLAN segments so parameter screens and future reads can't mistake a
     dead promo for a live one. Each expiry is logged with the from→to APR.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 3600]

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.AccountClosure, CMS.NonMonetaryEvent,
                 CMS.PlanSegment}
  alias VmuCore.FAS.AuthorizationRecord
  alias VmuCore.GL.LedgerQuery

  @system_operator_id "00000000-0000-0000-0000-000000000001"
  @batch_limit 1000

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    closures = AccountClosure.finalize_pending()
    flagged  = flag_dormant()
    cleared  = clear_dormant()
    promos   = expire_promos()

    Logger.info("[AccountLifecycleSweep] closures=#{closures.closed} " <>
                "still_blocked=#{closures.still_blocked} " <>
                "dormant_flagged=#{flagged} dormant_cleared=#{cleared} " <>
                "promos_expired=#{promos}")

    :ok
  end

  # ---------------------------------------------------------------------------
  # Promo expiry cleanup (CMS-G4.2)
  # ---------------------------------------------------------------------------

  defp expire_promos do
    today = Date.utc_today()

    expired =
      Repo.all(
        from p in PlanSegment,
          where: not is_nil(p.promo_apr) and not is_nil(p.promo_expiry_date)
             and p.promo_expiry_date < ^today,
          limit: @batch_limit
      )

    Enum.count(expired, fn plan ->
      Logger.info("[AccountLifecycleSweep] Promo expired: plan=#{plan.plan_id} " <>
                  "#{plan.sys_id}/#{plan.bank_id}/#{plan.logo_id} " <>
                  "#{plan.plan_type} APR #{plan.promo_apr}% → #{plan.apr}% " <>
                  "(promo ended #{plan.promo_expiry_date})")

      Repo.update_all(
        from(p in PlanSegment, where: p.plan_id == ^plan.plan_id),
        set: [promo_apr: nil, promo_expiry_date: nil,
              updated_at: NaiveDateTime.utc_now()]
      )

      true
    end)
  end

  # ---------------------------------------------------------------------------
  # Dormancy
  # ---------------------------------------------------------------------------

  # GL Phase C2 — "accounts posting since the cutoff", from the posting tables
  # via `GL.LedgerQuery`.
  #
  # Kept as a subquery rather than `account_refs/1`'s list: on a live portfolio
  # the set of recently-active accounts is most of the portfolio, and this runs
  # daily against every ACTIVE account.
  #
  # `product: "CREDIT"` is new, and deliberate. The legacy table mixed all five
  # products into one column, so this query was implicitly asking "any product's
  # activity" — harmless only because a debit account id could never collide
  # with a credit one. Dormancy here is a property of a `cms_accounts` row, so
  # the filter states that, and it is also what makes the `Ecto.UUID` cast in
  # `account_refs_query/1` safe.
  defp recent_ledger_activity(cutoff_date) do
    LedgerQuery.account_refs_query(
      product: "CREDIT",
      from: cutoff_date,
      as_uuid: true
    )
  end

  defp flag_dormant do
    cutoff_date = Date.add(Date.utc_today(), -dormancy_days())
    cutoff_dt   = DateTime.new!(cutoff_date, ~T[00:00:00], "Etc/UTC")

    recent_ledger = recent_ledger_activity(cutoff_date)

    recent_auths =
      from r in AuthorizationRecord,
        where: r.inserted_at >= ^cutoff_dt and not is_nil(r.account_id),
        select: r.account_id, distinct: true

    candidates =
      Repo.all(
        from a in Account,
          where: a.account_status == "ACTIVE"
             and is_nil(a.dormant_since)
             and (is_nil(a.last_payment_date) or a.last_payment_date < ^cutoff_date)
             and a.open_date < ^cutoff_date
             and a.account_id not in subquery(recent_ledger)
             and a.account_id not in subquery(recent_auths),
          limit: @batch_limit
      )

    Enum.count(candidates, fn account ->
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account.account_id),
        set: [dormant_since: Date.utc_today(), updated_at: NaiveDateTime.utc_now()]
      )

      NonMonetaryEvent.record(%{
        account_id:    account.account_id,
        event_type:    "dormancy_flagged",
        new_value:     %{"dormant_since" => to_string(Date.utc_today()),
                         "inactive_days" => dormancy_days()},
        operator_id:   @system_operator_id,
        operator_role: "SYSTEM"
      })

      true
    end)
  end

  defp clear_dormant do
    cutoff_date = Date.add(Date.utc_today(), -dormancy_days())
    cutoff_dt   = DateTime.new!(cutoff_date, ~T[00:00:00], "Etc/UTC")

    recent_ledger = recent_ledger_activity(cutoff_date)

    recent_auths =
      from r in AuthorizationRecord,
        where: r.inserted_at >= ^cutoff_dt and not is_nil(r.account_id),
        select: r.account_id, distinct: true

    flagged_with_activity =
      Repo.all(
        from a in Account,
          where: not is_nil(a.dormant_since)
             and ((not is_nil(a.last_payment_date) and a.last_payment_date >= ^cutoff_date)
                  or a.account_id in subquery(recent_ledger)
                  or a.account_id in subquery(recent_auths)),
          limit: @batch_limit
      )

    Enum.count(flagged_with_activity, fn account ->
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account.account_id),
        set: [dormant_since: nil, updated_at: NaiveDateTime.utc_now()]
      )

      NonMonetaryEvent.record(%{
        account_id:    account.account_id,
        event_type:    "dormancy_cleared",
        old_value:     %{"dormant_since" => to_string(account.dormant_since)},
        operator_id:   @system_operator_id,
        operator_role: "SYSTEM"
      })

      true
    end)
  end

  defp dormancy_days, do: Application.get_env(:vmu_core, :cms_dormancy_days, 365)
end
