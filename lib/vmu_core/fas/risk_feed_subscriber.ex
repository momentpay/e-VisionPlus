defmodule VmuCore.FAS.RiskFeedSubscriber do
  @moduledoc """
  PubSub relay: forwards mw_risk :decline events to the FAS admin dashboard (FAS-P8 8B).

  Subscribes to `"risk:scores"` on `VmuCore.PubSub` and rebroadcasts any
  `:decline` decision to `"fas:risk_alerts"` so the admin dashboard can surface
  real-time fraud alerts without polling.

  ## mw_risk PubSub configuration

  mw_risk does not broadcast by default. Enable with:

      config :mw_risk, :publish_scores, true
      config :mw_risk, :pubsub_name, VmuCore.PubSub

  When disabled, this subscriber starts cleanly but never receives messages —
  the admin dashboard simply shows no live alerts.

  ## Event shape

  Broadcasts `{:fas_risk_alert, payload}` on `"fas:risk_alerts"` where
  `payload` is the raw map received from mw_risk:

      %{
        decision:      :decline,
        score:         0.95,
        fired_rules:   ["Very high value transaction"],
        model_version: "v1",
        tenant_id:     1
      }

  The admin dashboard LiveView subscribes to `"fas:risk_alerts"` and renders
  a scrolling alert feed via `Phoenix.PubSub.subscribe/2` in `mount/3`.
  """

  use GenServer
  require Logger

  @topic       "risk:scores"
  @alert_topic "fas:risk_alerts"

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    Phoenix.PubSub.subscribe(VmuCore.PubSub, @topic)
    Logger.info("[RiskFeedSubscriber] subscribed to PubSub topic #{@topic}")
    {:ok, %{decline_count: 0, total_count: 0}}
  end

  @impl true
  def handle_info({:risk_score, %{decision: :decline} = payload}, state) do
    Phoenix.PubSub.broadcast(VmuCore.PubSub, @alert_topic, {:fas_risk_alert, payload})
    {:noreply, %{state | decline_count: state.decline_count + 1,
                          total_count:  state.total_count + 1}}
  end

  def handle_info({:risk_score, _payload}, state) do
    {:noreply, %{state | total_count: state.total_count + 1}}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @doc "Return current alert stats (for health-check / admin API)."
  @spec stats() :: %{decline_count: non_neg_integer(), total_count: non_neg_integer()}
  def stats do
    GenServer.call(__MODULE__, :stats)
  end

  @impl true
  def handle_call(:stats, _from, state) do
    {:reply, Map.take(state, [:decline_count, :total_count]), state}
  end
end
