defmodule VmuCore.FAS.Telemetry do
  @moduledoc """
  FAS telemetry event definitions and emit helpers (FAS-P8 8A).

  ## Events emitted

  | Event                              | Measurements              | Metadata                     |
  |------------------------------------|---------------------------|------------------------------|
  | `[:vmu_core, :fas, :authorization]`| duration (native), count  | rc, decision, mti, stip_used |
  | `[:vmu_core, :fas, :risk_call]`    | duration (native)         | decision                     |
  | `[:vmu_core, :fas, :stip]`         | count                     | rc                           |
  | `[:vmu_core, :fas, :hold_aging]`   | expired_count             | oldest_minutes               |

  ## Usage

      # In authorization.ex around the route/2 call:
      start = System.monotonic_time()
      result = route(mti, fields)
      FasTelemetry.execute_auth(rc, decision, System.monotonic_time() - start,
        %{mti: mti, stip_used: false})

      # In risk_adapter.ex around MwRisk.Pipeline.run/2:
      start = System.monotonic_time()
      result = MwRisk.Pipeline.run(...)
      FasTelemetry.execute_risk_call(System.monotonic_time() - start, result.decision)

  ## LiveDashboard integration

  `VmuCoreWeb.Telemetry.metrics/0` calls `FasTelemetry.metrics/0` to include
  these in the existing LiveDashboard at /dashboard. No additional setup needed.
  """

  @auth_event      [:vmu_core, :fas, :authorization]
  @risk_call_event [:vmu_core, :fas, :risk_call]
  @stip_event      [:vmu_core, :fas, :stip]
  @hold_event      [:vmu_core, :fas, :hold_aging]

  @doc """
  Emit an authorization telemetry event.

  - `rc`       — ISO 8583 response code string (e.g. "00", "05")
  - `decision` — `:approved` or `:declined`
  - `duration` — wall-clock in `System.monotonic_time/0` native units
  - `meta`     — optional map with `:mti`, `:stip_used`
  """
  @spec execute_auth(String.t(), :approved | :declined, integer(), map()) :: :ok
  def execute_auth(rc, decision, duration, meta \\ %{}) do
    :telemetry.execute(@auth_event, %{duration: duration, count: 1},
      Map.merge(%{rc: rc, decision: decision}, meta))
  end

  @doc "Emit a mw_risk call telemetry event."
  @spec execute_risk_call(integer(), :approve | :review | :decline) :: :ok
  def execute_risk_call(duration, decision) do
    :telemetry.execute(@risk_call_event, %{duration: duration, count: 1}, %{decision: decision})
  end

  @doc "Emit a STIP (stand-in processing) telemetry event."
  @spec execute_stip(String.t()) :: :ok
  def execute_stip(rc) do
    :telemetry.execute(@stip_event, %{count: 1}, %{rc: rc})
  end

  @doc "Emit a hold aging alert event (from HoldAgingMonitor)."
  @spec execute_hold_aging(non_neg_integer(), non_neg_integer()) :: :ok
  def execute_hold_aging(expired_count, oldest_minutes) do
    :telemetry.execute(@hold_event, %{expired_count: expired_count},
      %{oldest_minutes: oldest_minutes})
  end

  @doc """
  Telemetry.Metrics definitions for FAS — merged into `VmuCoreWeb.Telemetry.metrics/0`.
  """
  def metrics do
    import Telemetry.Metrics

    [
      # Authorization throughput
      counter("vmu_core.fas.authorization.count",
        description: "Total FAS authorization requests (all MTIs, all outcomes)"),
      counter("vmu_core.fas.authorization.count",
        tags: [:decision],
        tag_values: &Map.take(&1, [:decision]),
        description: "Authorization count partitioned by approved/declined"),
      counter("vmu_core.fas.authorization.count",
        tags: [:rc],
        tag_values: &Map.take(&1, [:rc]),
        description: "Authorization count by ISO 8583 response code (RC distribution)"),

      # Authorization latency
      summary("vmu_core.fas.authorization.duration",
        unit: {:native, :millisecond},
        description: "FAS end-to-end authorization latency (route → result)"),

      # STIP stand-in
      counter("vmu_core.fas.stip.count",
        description: "Stand-in authorizations (AccountStateCoordinator unreachable)"),

      # mw_risk integration
      summary("vmu_core.fas.risk_call.duration",
        unit: {:native, :millisecond},
        description: "mw_risk Pipeline.run/2 latency"),
      counter("vmu_core.fas.risk_call.count",
        tags: [:decision],
        tag_values: &Map.take(&1, [:decision]),
        description: "mw_risk decision distribution (approve/review/decline)"),

      # Hold aging
      last_value("vmu_core.fas.hold_aging.expired_count",
        description: "Expired uncleaned pending holds at last check")
    ]
  end
end
