defmodule VmuCore.CTA.CardStateMachine do
  @moduledoc """
  Card plastic lifecycle (CTA-P1.3, FR-013). Pure module — no I/O.

  ## States

      ORDERED → EMBOSSED → DISPATCHED → INACTIVE → ACTIVE
                                          │           │
                                          │       BLOCKED ⟲ (unblock → ACTIVE)
                                          │           │
      ACTIVE / BLOCKED / INACTIVE ────────┴──────► EXPIRED   (expiry sweep)
      ACTIVE / BLOCKED / INACTIVE / EXPIRED ─────► REPLACED  (superseded by new gen)
      any non-terminal ──────────────────────────► DESTROYED (return-to-sender / manual)

  - `INACTIVE` is the state a freshly personalized card sits in awaiting
    cardholder activation. Virtual/instant cards may be issued straight to
    `INACTIVE` (skipping ORDERED/EMBOSSED/DISPATCHED).
  - Terminal states: EXPIRED, REPLACED, DESTROYED — no further transitions.
  - Self-transitions are allowed (idempotent redelivery of a lifecycle event).
  """

  @states ~w[ORDERED EMBOSSED DISPATCHED INACTIVE ACTIVE BLOCKED
             EXPIRED REPLACED DESTROYED]

  @terminal ~w[EXPIRED REPLACED DESTROYED]

  @transitions %{
    "ORDERED"    => ~w[EMBOSSED DESTROYED REPLACED],
    "EMBOSSED"   => ~w[DISPATCHED DESTROYED REPLACED],
    "DISPATCHED" => ~w[INACTIVE DESTROYED REPLACED],
    "INACTIVE"   => ~w[ACTIVE BLOCKED EXPIRED REPLACED DESTROYED],
    "ACTIVE"     => ~w[BLOCKED EXPIRED REPLACED DESTROYED],
    "BLOCKED"    => ~w[ACTIVE EXPIRED REPLACED DESTROYED],
    "EXPIRED"    => ~w[REPLACED],
    "REPLACED"   => [],
    "DESTROYED"  => []
  }

  @spec states() :: [String.t()]
  def states, do: @states

  @spec terminal?(String.t()) :: boolean()
  def terminal?(state), do: state in @terminal

  @doc """
  Validate a transition. Returns `{:ok, to}` (including the idempotent
  `from == to` case) or `{:error, {:invalid_transition, from, to}}`.
  """
  @spec transition(String.t(), String.t()) ::
          {:ok, String.t()} | {:error, {:invalid_transition, String.t(), String.t()}}
  def transition(from, to) do
    cond do
      from == to -> {:ok, to}
      to in Map.get(@transitions, from, []) -> {:ok, to}
      true -> {:error, {:invalid_transition, from, to}}
    end
  end

  @doc "Allowed next states from `state` (excludes the idempotent self-transition)."
  @spec allowed_from(String.t()) :: [String.t()]
  def allowed_from(state), do: Map.get(@transitions, state, [])
end
