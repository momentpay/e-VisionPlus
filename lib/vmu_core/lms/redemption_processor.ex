defmodule VmuCore.LMS.RedemptionProcessor do
  @moduledoc """
  Processes points redemption requests.

  Redemption rules:
    - Account must not be BLOCKED or DELINQUENT
    - open_to_redeem must be >= points requested
    - Points are deducted oldest-first (FIFO across ACTIVE ledger entries)
    - Consumed entries move to HISTORY state; partially consumed stay ACTIVE
    - A Redemption record is created with status PENDING (disbursement is async)
  """

  require Logger
  alias VmuCore.LMS.{Account, PointsLedger, Redemption}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @doc """
  Redeem points from a LMS account.
  Returns {:ok, redemption} or {:error, reason}.
  """
  def redeem(lms_account_id, points_requested, opts \\ []) do
    redemption_type     = Keyword.get(opts, :type, "ONLINE")
    disbursement_method = Keyword.get(opts, :method, "CREDIT")

    Repo.transaction(fn ->
      account = lock_account!(lms_account_id)

      with :ok <- check_eligibility(account),
           :ok <- check_open_to_redeem(account, D.new(points_requested)) do
        deduct_points_oldest_first(account, D.new(points_requested))
        redemption = create_redemption_record(
          account, points_requested, redemption_type, disbursement_method)
        update_account_redeemed(lms_account_id, D.new(points_requested))
        redemption
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp lock_account!(id) do
    Repo.one!(from a in Account, where: a.id == ^id, lock: "FOR UPDATE")
  end

  defp check_eligibility(%Account{status: status}) when status in ["BLOCKED", "DELINQUENT"] do
    {:error, :account_ineligible}
  end
  defp check_eligibility(_), do: :ok

  defp check_open_to_redeem(%Account{open_to_redeem: avail}, requested) do
    if D.lt?(avail, requested),
      do: {:error, :insufficient_open_to_redeem},
      else: :ok
  end

  defp deduct_points_oldest_first(account, total) do
    active_entries =
      from(l in PointsLedger,
        where: l.lms_account_id == ^account.id
          and l.warehouse_state == "ACTIVE"
          and l.points_amount > 0,
        order_by: [asc: l.transaction_date, asc: l.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    do_deduct(active_entries, total)
  end

  defp do_deduct([], _remaining), do: :ok
  defp do_deduct(_entries, remaining) when remaining <= 0, do: :ok
  defp do_deduct([entry | rest], remaining) do
    deductible  = D.min(D.new(entry.points_amount), remaining)
    new_balance = D.sub(D.new(entry.points_amount), deductible)

    new_state = if D.eq?(new_balance, D.new(0)), do: "HISTORY", else: "ACTIVE"

    Repo.update_all(
      from(l in PointsLedger, where: l.id == ^entry.id),
      set: [points_amount: new_balance, warehouse_state: new_state]
    )

    do_deduct(rest, D.sub(remaining, deductible))
  end

  defp create_redemption_record(account, points, type, method) do
    monetary_value = calculate_monetary_value(account.scheme_id, points)

    %Redemption{}
    |> Redemption.changeset(%{
      lms_account_id:     account.id,
      redemption_type:    type,
      points_redeemed:    points,
      monetary_value:     monetary_value,
      disbursement_method: method,
      status:             "PENDING",
      idempotency_key:    "redeem_#{account.id}_#{System.unique_integer([:positive])}",
      inserted_at:        DateTime.utc_now()
    })
    |> Repo.insert!()
  end

  defp update_account_redeemed(lms_account_id, points) do
    Repo.update_all(
      from(a in Account, where: a.id == ^lms_account_id),
      inc: [lifetime_redeemed: points]
    )
    Repo.update_all(
      from(a in Account, where: a.id == ^lms_account_id),
      set: [open_to_redeem: Decimal.new(0)]  # recalculated nightly
    )
  end

  defp calculate_monetary_value(scheme_id, points) do
    rate_pct = Application.get_env(:vmu_core, [:lms, :schemes, scheme_id, :redemption_rate_pct], "0.01")
               |> D.new()
    D.mult(D.new(points), rate_pct) |> D.round(2)
  end
end
