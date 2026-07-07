defmodule VmuCore.FAS.HoldAgingMonitor do
  @moduledoc """
  Polls `fas_pending_holds` for expired, uncleared holds (FAS-P8 8C).

  Holds expire when the card network's pre-auth window closes (hotel, car
  rental, fuel pump) but the clearing record never arrived. These holds
  permanently reduce the cardholder's OTB unless an operator or scheduled job
  clears them.

  ## What it does

  Every `@check_interval_ms` (60 s), queries for holds where:
    - `expires_at` is in the past
    - `cleared_at` and `reversal_at` are both null (still active)
    - age exceeds the configured `hold_aging_alert_threshold_mins` (default 60)

  If any are found:
    1. Broadcasts `{:hold_aging_alert, %{expired_count: n, oldest_minutes: m}}`
       to PubSub topic `"fas:hold_alerts"` (admin dashboard subscribes here)
    2. Emits the `[:vmu_core, :fas, :hold_aging]` telemetry event (LiveDashboard)

  ## Configuration

      config :vmu_core, :hold_aging_alert_threshold_mins, 60  # default

  Set to 0 to alert on every expired hold immediately.

  ## Admin response

  The exception queue admin UI (`ExceptionQueueComponent`) surfaces these
  holds alongside unmatched reversals so an operator can manually clear them
  or trigger a re-presentment to settlement_core.
  """

  use GenServer
  require Logger

  import Ecto.Query

  alias VmuCore.{Repo, FAS.PendingHold, FAS.Telemetry}

  @alert_topic     "fas:hold_alerts"
  @check_interval  60_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    schedule_check()
    {:ok, %{last_expired_count: 0}}
  end

  @impl true
  def handle_info(:check_aging, state) do
    expired_count = check_and_broadcast()
    schedule_check()
    {:noreply, %{state | last_expired_count: expired_count}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Current count of expired uncleaned holds (synchronous query)."
  @spec expired_count() :: non_neg_integer()
  def expired_count do
    threshold_mins = alert_threshold_mins()
    cutoff = DateTime.add(DateTime.utc_now(), -threshold_mins * 60, :second)

    from(h in PendingHold,
      where: is_nil(h.cleared_at) and is_nil(h.reversal_at) and h.expires_at < ^cutoff,
      select: count(h.id)
    )
    |> Repo.one() || 0
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_and_broadcast do
    threshold_mins = alert_threshold_mins()
    cutoff         = DateTime.add(DateTime.utc_now(), -threshold_mins * 60, :second)

    {count, oldest_ts} =
      from(h in PendingHold,
        where: is_nil(h.cleared_at) and is_nil(h.reversal_at) and h.expires_at < ^cutoff,
        select: {count(h.id), min(h.expires_at)}
      )
      |> Repo.one()

    count = count || 0

    if count > 0 do
      oldest_minutes = age_minutes(oldest_ts)
      payload = %{expired_count: count, oldest_minutes: oldest_minutes}

      Phoenix.PubSub.broadcast(VmuCore.PubSub, @alert_topic, {:hold_aging_alert, payload})
      Telemetry.execute_hold_aging(count, oldest_minutes)

      Logger.warning("[HoldAgingMonitor] #{count} expired uncleaned hold(s); " <>
                     "oldest #{oldest_minutes}m past expiry")
    end

    count
  rescue
    e ->
      Logger.error("[HoldAgingMonitor] check failed: #{Exception.message(e)}")
      0
  end

  defp age_minutes(nil), do: 0
  defp age_minutes(ts) do
    DateTime.diff(DateTime.utc_now(), ts, :second) |> div(60)
  end

  defp alert_threshold_mins do
    Application.get_env(:vmu_core, :hold_aging_alert_threshold_mins, 60)
  end

  defp schedule_check do
    Process.send_after(self(), :check_aging, @check_interval)
  end
end
