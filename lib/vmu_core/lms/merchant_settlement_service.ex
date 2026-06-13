defmodule VmuCore.LMS.MerchantSettlementService do
  @moduledoc """
  Calculates and records merchant settlement for all bonus groups in a given period.

  Called from the EOD settlement job (monthly or configurable frequency).
  For each bonus group:
    1. Sum all unsettled BONUS_EARNED points in the period
    2. Calculate settlement amount = total_points × charge_rate_pct
    3. Insert lms_merchant_settlement record
    4. Post GL via GlProvisioner.post_merchant_settlement/1
    5. Mark ledger entries as settled
  """

  require Logger
  alias VmuCore.LMS.{Group, PointsLedger, MerchantSettlement, GlProvisioner}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @doc "Run settlement for all active bonus groups in the given date range."
  def run_settlement(period_from, period_to) do
    Logger.info("[LMS/Settlement] Running for #{period_from} → #{period_to}")

    bonus_groups =
      from(g in Group, where: g.group_type == "BONUS" and g.status == "ACTIVE")
      |> Repo.all()

    Enum.each(bonus_groups, &settle_group(&1, period_from, period_to))

    Logger.info("[LMS/Settlement] Completed for #{length(bonus_groups)} groups")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp settle_group(group, period_from, period_to) do
    total_bonus_points =
      from(l in PointsLedger,
        where: l.group_id == ^group.id
          and l.transaction_type == "BONUS_EARNED"
          and l.transaction_date >= ^period_from
          and l.transaction_date <= ^period_to
          and is_nil(l.settled_at),
        select: sum(l.points_amount)
      )
      |> Repo.one()

    total = (total_bonus_points && D.new(total_bonus_points)) || D.new(0)

    if D.gt?(total, D.new(0)) do
      charge_rate = charge_rate_for_group(group.id)
      amount      = D.mult(total, charge_rate) |> D.round(2)

      settlement =
        %MerchantSettlement{}
        |> MerchantSettlement.changeset(%{
          group_id:             group.id,
          settlement_period_from: period_from,
          settlement_period_to:   period_to,
          total_bonus_points:   total,
          charge_rate_pct:      charge_rate,
          settlement_amount:    amount,
          settlement_method:    "DIRECT_DEBIT",
          status:               "PENDING",
          inserted_at:          DateTime.utc_now()
        })
        |> Repo.insert!()

      GlProvisioner.post_merchant_settlement(settlement)

      Repo.update_all(
        from(l in PointsLedger,
          where: l.group_id == ^group.id
            and l.transaction_type == "BONUS_EARNED"
            and l.transaction_date >= ^period_from
            and l.transaction_date <= ^period_to
            and is_nil(l.settled_at)
        ),
        set: [settled_at: DateTime.utc_now()]
      )

      Logger.info("[LMS/Settlement] Group #{group.id}: #{total} pts → #{amount}")
    end
  end

  defp charge_rate_for_group(group_id) do
    Application.get_env(:vmu_core, [:lms, :groups, group_id, :charge_rate_pct], "0.005")
    |> D.new()
  end
end
