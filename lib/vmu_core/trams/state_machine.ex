defmodule VmuCore.TRAMS.StateMachine do
  @moduledoc """
  Transaction lifecycle state machine (TRAM-P1 1D, spec Section 7.2).

  Pure module — no I/O. `VmuCore.TRAMS.EventStore` calls `apply_event/2`
  inside its DB transaction to validate and derive the state projection.

  ## States (spec §7.2, 13-state lifecycle + DECLINED for research)

      INITIATED → AUTHORIZED → AUTH_MAINTENANCE ⟲ → CLEARED → POSTED
           └→ DECLINED             └→ REVERSED         → STATEMENTED → PAID
      POSTED / STATEMENTED / PAID → DISPUTED → CHARGEBACKED → RESOLVED
      terminal-ish states → CLOSED → ARCHIVED

  ## Rules

  - Self-transitions are always allowed (idempotent event redelivery — e.g.
    a second 0200 completion, or settlement_matched after completion already
    moved the transaction to CLEARED).
  - Audit-only events (`adjustment_applied`, `maintenance_applied`,
    `settlement_received`, `identifier_added`) never change state and are
    valid in any state.
  - Everything else must follow the transition table or the append is
    rejected with `{:error, :invalid_transition}` — invalid sequences are a
    data-integrity signal, not something to silently absorb.
  """

  @states ~w[
    INITIATED AUTHORIZED DECLINED AUTH_MAINTENANCE REVERSED CLEARED POSTED
    STATEMENTED PAID DISPUTED CHARGEBACKED RESOLVED CLOSED ARCHIVED
  ]

  @transitions %{
    "INITIATED"        => ~w[AUTHORIZED DECLINED],
    "AUTHORIZED"       => ~w[AUTH_MAINTENANCE REVERSED CLEARED DISPUTED],
    "AUTH_MAINTENANCE" => ~w[REVERSED CLEARED DISPUTED],
    "CLEARED"          => ~w[POSTED DISPUTED],
    "POSTED"           => ~w[STATEMENTED DISPUTED CLOSED],
    "STATEMENTED"      => ~w[PAID DISPUTED CLOSED],
    "PAID"             => ~w[DISPUTED CLOSED],
    "DISPUTED"         => ~w[CHARGEBACKED RESOLVED],
    "CHARGEBACKED"     => ~w[RESOLVED CLOSED],
    "RESOLVED"         => ~w[CLOSED],
    "REVERSED"         => ~w[CLOSED],
    "DECLINED"         => ~w[CLOSED],
    "CLOSED"           => ~w[ARCHIVED],
    "ARCHIVED"         => []
  }

  # event_type → target state. Events not listed here are audit-only.
  @event_state %{
    "authorization_approved"           => "AUTHORIZED",
    "authorization_declined"           => "DECLINED",
    "incremental_authorization"        => "AUTH_MAINTENANCE",
    "authorization_partially_reversed" => "AUTH_MAINTENANCE",
    "authorization_reversed"           => "REVERSED",
    "authorization_expired"            => "REVERSED",
    "completion_received"              => "CLEARED",
    "settlement_matched"               => "CLEARED",
    "transaction_posted"               => "POSTED",
    "statement_generated"              => "STATEMENTED",
    "payment_allocated"                => "PAID",
    "dispute_created"                  => "DISPUTED",
    "chargeback_created"               => "CHARGEBACKED",
    "chargeback_reversed"              => "RESOLVED",
    "dispute_resolved"                 => "RESOLVED",
    "transaction_closed"               => "CLOSED",
    "transaction_archived"             => "ARCHIVED"
  }

  @stateless_events ~w[
    adjustment_applied maintenance_applied settlement_received identifier_added
    dispute_stage_changed
  ]

  @doc "All valid lifecycle states."
  @spec states() :: [String.t()]
  def states, do: @states

  @doc "All known event types (state-changing + audit-only)."
  @spec event_types() :: [String.t()]
  def event_types, do: Map.keys(@event_state) ++ @stateless_events

  @doc """
  Apply an event to the current state.

  Returns `{:ok, new_state}` (which may equal `current_state` for audit-only
  events or idempotent redelivery) or `{:error, :invalid_transition}` /
  `{:error, :unknown_event}`.
  """
  @spec apply_event(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_transition | :unknown_event}
  def apply_event(current_state, event_type) do
    cond do
      event_type in @stateless_events ->
        {:ok, current_state}

      not Map.has_key?(@event_state, event_type) ->
        {:error, :unknown_event}

      true ->
        target = @event_state[event_type]

        cond do
          target == current_state ->
            {:ok, current_state}

          target in Map.get(@transitions, current_state, []) ->
            {:ok, target}

          true ->
            {:error, :invalid_transition}
        end
    end
  end

  @doc "True when the state permits no further lifecycle activity except archival/closure."
  @spec terminal?(String.t()) :: boolean()
  def terminal?(state), do: state in ~w[CLOSED ARCHIVED]

  @doc """
  Fold an ordered list of event types over an initial state — used for
  statement regeneration / "what was true as of cutoff" queries (spec 07
  §2.4). Unknown or invalid events are skipped (historical log may contain
  event types added later).
  """
  @spec derive_state([String.t()], String.t()) :: String.t()
  def derive_state(event_types, initial_state \\ "INITIATED") do
    Enum.reduce(event_types, initial_state, fn event_type, state ->
      case apply_event(state, event_type) do
        {:ok, new_state} -> new_state
        {:error, _}      -> state
      end
    end)
  end
end
