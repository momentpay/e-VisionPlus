defmodule VmuCore.LMS.PointsEngine do
  @moduledoc """
  Core points calculation engine — called from the CMS→LMS interface batch job.

  For each matched clearing transaction:
    1. Find all active LMS enrollments for the AR account
    2. For each enrollment: apply default group (always) + bonus groups (if merchant linked)
    3. For each group: resolve active plans for transaction date
    4. For each plan: calculate points and post to lms_points_ledger (idempotent)
    5. Update account balance totals
    6. Post provisioning GL entry
  """

  require Logger
  alias VmuCore.LMS.{Account, Group, PointsLedger, RateEngine, GlProvisioner}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @doc """
  Processes a single clearing transaction for all enrolled schemes of an AR account.
  Called from LMS.Oban.PointsCalculationJob for each clearing record.
  """
  def process_transaction(ar_account_id, txn) do
    %{amount: amount, transaction_date: txn_date,
      merchant_id: merchant_id, clearing_record_id: clearing_id} = txn

    enrollments =
      from(a in Account,
        where: a.ar_account_id == ^ar_account_id and a.status == "ACTIVE",
        preload: [scheme: :groups]
      )
      |> Repo.all()

    Enum.each(enrollments, fn lms_account ->
      process_for_enrollment(lms_account, amount, txn_date, merchant_id, clearing_id)
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp process_for_enrollment(lms_account, amount, txn_date, merchant_id, clearing_id) do
    scheme = lms_account.scheme
    groups = scheme.groups

    default_group = Enum.find(groups, &(&1.group_type == "DEFAULT"))
    bonus_groups  = find_bonus_groups(groups, merchant_id)

    [default_group | bonus_groups]
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn group ->
      plans = RateEngine.resolve_active_plans(group.id, txn_date)
      Enum.each(plans, fn plan ->
        case RateEngine.calculate_points(plan.id, D.new(amount)) do
          {:ok, points} ->
            post_earned_points(lms_account, group, plan, points, amount, txn_date, clearing_id)
          {:error, reason} ->
            Logger.debug("[LMS] No points for plan=#{plan.id} amount=#{amount}: #{reason}")
        end
      end)
    end)
  end

  defp post_earned_points(lms_account, group, plan, points, amount, txn_date, clearing_id) do
    txn_type      = if group.group_type == "DEFAULT", do: "BASIC_EARNED", else: "BONUS_EARNED"
    warehouse_days = lms_account.scheme.warehouse_days
    warehouse_state = if warehouse_days > 0, do: "WAREHOUSE", else: "ACTIVE"

    expiry_date =
      case lms_account.scheme.points_expiry_months do
        nil    -> nil
        months -> Date.add(txn_date, months * 30)
      end

    idempotency_key =
      :crypto.hash(:sha256, "lms_earn_#{clearing_id}_#{plan.id}")
      |> Base.encode16(case: :lower)

    changeset =
      %PointsLedger{}
      |> PointsLedger.changeset(%{
        lms_account_id:     lms_account.id,
        transaction_type:   txn_type,
        points_amount:      points,
        monetary_equiv:     D.new(amount),
        transaction_date:   txn_date,
        posting_date:       Date.utc_today(),
        expiry_date:        expiry_date,
        warehouse_state:    warehouse_state,
        plan_id:            plan.id,
        group_id:           group.id,
        scheme_id:          lms_account.scheme_id,
        source_clearing_id: clearing_id,
        idempotency_key:    idempotency_key,
        inserted_at:        DateTime.utc_now()
      })

    case Repo.insert(changeset, on_conflict: :nothing, conflict_target: :idempotency_key) do
      {:ok, %PointsLedger{id: nil}} ->
        :ok  # duplicate — already processed

      {:ok, entry} ->
        update_account_balance(lms_account.id, points)
        GlProvisioner.post_provisioning(lms_account.scheme_id, entry)
        Logger.debug("[LMS] Earned #{points} pts for account=#{lms_account.id} plan=#{plan.id}")

      {:error, cs} ->
        Logger.error("[LMS] Failed to post points: #{inspect(cs.errors)}")
    end
  end

  defp update_account_balance(lms_account_id, points) do
    Repo.update_all(
      from(a in Account, where: a.id == ^lms_account_id),
      inc: [points_balance: points, lifetime_earned: points]
    )
  end

  defp find_bonus_groups(_groups, nil), do: []
  defp find_bonus_groups(groups, merchant_id) do
    group_ids = Enum.map(groups, & &1.id)

    from(g in Group,
      join: gm in "lms_group_merchants", on: gm.group_id == g.id,
      where: g.id in ^group_ids and g.group_type == "BONUS"
        and gm.merchant_id == ^merchant_id
    )
    |> Repo.all()
  end
end
