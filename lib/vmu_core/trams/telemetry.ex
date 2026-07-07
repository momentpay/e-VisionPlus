defmodule VmuCore.TRAMS.Telemetry do
  @moduledoc """
  TRAM telemetry (TRAM-P6 6F) — mirrors the `VmuCore.FAS.Telemetry` pattern.

  ## Events

  | Event | Measurements | Metadata |
  |---|---|---|
  | `[:vmu_core, :trams, :event_appended]` | count | event_type, new_state |
  | `[:vmu_core, :trams, :match]`          | count | outcome (matched/exception) |

  Emitted from `EventStore.append/4` (every lifecycle event) and
  `MatchingEngine.match_clearing_record/1`. `metrics/0` is merged into
  `VmuCoreWeb.Telemetry.metrics/0` for LiveDashboard.
  """

  @event_appended [:vmu_core, :trams, :event_appended]
  @match          [:vmu_core, :trams, :match]

  @doc "Emit a lifecycle-event-appended telemetry event."
  @spec execute_event(String.t(), String.t()) :: :ok
  def execute_event(event_type, new_state) do
    :telemetry.execute(@event_appended, %{count: 1},
      %{event_type: event_type, new_state: new_state})
  end

  @doc "Emit a clearing-match outcome telemetry event."
  @spec execute_match(:matched | :exception) :: :ok
  def execute_match(outcome) do
    :telemetry.execute(@match, %{count: 1}, %{outcome: outcome})
  end

  @doc "Telemetry.Metrics definitions — merged into VmuCoreWeb.Telemetry."
  def metrics do
    import Telemetry.Metrics

    [
      counter("vmu_core.trams.event_appended.count",
        description: "TRAM lifecycle events appended (all types)"),
      counter("vmu_core.trams.event_appended.count",
        tags: [:event_type],
        tag_values: &Map.take(&1, [:event_type]),
        description: "TRAM lifecycle events by type"),
      counter("vmu_core.trams.match.count",
        tags: [:outcome],
        tag_values: &Map.take(&1, [:outcome]),
        description: "Clearing match outcomes (matched vs exception)")
    ]
  end
end
