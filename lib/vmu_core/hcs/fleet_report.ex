defmodule VmuCore.HCS.FleetReport do
  @moduledoc """
  Fleet spend reporting (Way4 parity plan Phase 1 item 3, 2026-07-25).

  v1-scoped deliberately: no fuel-line-item detail (no real acquirer
  fuel-dispenser spec sourced — merchant category / gallons / product
  type would need a real fuel network feed we don't have), and
  `spend_by_driver/3` attributes 100% of a vehicle's period spend to
  whichever driver is CURRENTLY assigned — it does NOT split spend
  across a mid-period driver reassignment. This is a known simplification
  carried forward honestly from the original design, not silently
  dropped.
  """

  alias VmuCore.HCS.{FleetCard, Vehicle, DriverAssignmentCommand}
  alias VmuCore.GL.LedgerQuery
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  def spend_by_vehicle(company_id, period_from, period_to) do
    cards =
      from(fc in FleetCard, where: fc.company_id == ^company_id,
        join: v in Vehicle, on: v.id == fc.vehicle_id,
        select: {fc, v})
      |> Repo.all()

    Enum.map(cards, fn {card, vehicle} ->
      %{
        vehicle_id: vehicle.id, plate_number: vehicle.plate_number,
        vin: vehicle.vin, fleet_card_id: card.id,
        spend: sum_spend(card.account_id, period_from, period_to)
      }
    end)
  end

  def spend_by_driver(company_id, period_from, period_to) do
    company_id
    |> spend_by_vehicle(period_from, period_to)
    |> Enum.map(fn row ->
      driver =
        case DriverAssignmentCommand.current_assignment(row.vehicle_id) do
          nil -> nil
          assignment -> assignment.driver_name
        end

      Map.put(row, :driver_name, driver)
    end)
    |> Enum.group_by(& &1.driver_name)
    |> Enum.map(fn {driver_name, rows} ->
      %{
        driver_name: driver_name || "UNASSIGNED",
        vehicles: length(rows),
        spend: Enum.reduce(rows, D.new(0), &D.add(&1.spend, &2))
      }
    end)
  end

  def total_spend(company_id, period_from, period_to) do
    company_id
    |> spend_by_vehicle(period_from, period_to)
    |> Enum.reduce(D.new(0), &D.add(&1.spend, &2))
  end

  defp sum_spend(account_id, period_from, period_to) do
    start_dt = DateTime.new!(period_from, ~T[00:00:00], "Etc/UTC")
    end_dt   = DateTime.new!(period_to,   ~T[23:59:59], "Etc/UTC")

    # GL Phase C2 — see `GL.LedgerQuery`.
    #
    # `inserted_from`/`inserted_to` and not `from`/`to`: this window has always
    # been over **row-write time**, not posting date, and the two differ for
    # any backdated posting. Migrating it onto `posting_date` would silently
    # change which activity a fleet report covers.
    #
    # HCS rides on `cms_accounts` — `HCS.FleetOnboarding` provisions a real
    # `CMS.Account` per vehicle and stores its id here — so these accounts
    # resolve as product `CREDIT` and their postings were mirrored like any
    # other. Verified against live data 2026-08-05: 135 legacy rows, 135
    # journal entries, totals equal per account.
    LedgerQuery.sum_amount(
      account_ref: account_id,
      inserted_from: start_dt,
      inserted_to: end_dt
    )
  end
end
