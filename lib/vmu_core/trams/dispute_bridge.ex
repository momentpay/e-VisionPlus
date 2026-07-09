defmodule VmuCore.TRAMS.DisputeBridge do
  @moduledoc """
  TRAM ↔ DPS dispute linkage (TRAM-P5 5C, spec 08, ADR-T5).

  DPS keeps everything it already owns — the dispute state machine,
  provisional credit GL posting, and Oban deadline enforcement. This bridge:

  1. **Files disputes from a TRAM transaction** — validates the dispute
     window, delegates to `DPS.Dispute.file/1` with `trams_transaction_id`
     linked, and appends `dispute_created` → DISPUTED to the aggregate.
  2. **Mirrors DPS lifecycle transitions** into the TRAM event log
     (`notify_transition/1`, called fail-safe from `DPS.Dispute.transition/2`)
     so the transaction timeline in Inquiry shows the complete dispute
     journey.

  ## DPS status → TRAM event mapping

  | DPS status | TRAM event | State effect |
  |---|---|---|
  | CHARGEBACK_FILED | `chargeback_created` | → CHARGEBACKED |
  | CLOSED_WIN (issuer/cardholder wins) | `dispute_resolved` | → RESOLVED |
  | CLOSED_LOSE (merchant wins — provisional credit reversed) | `chargeback_reversed` | → RESOLVED |
  | CANCELLED | `dispute_resolved` | → RESOLVED |
  | RETRIEVAL_REQUESTED / REPRESENTED / PRE_ARB / ARBITRATION | `dispute_stage_changed` | none (audit-only) |

  ## Configuration

      config :vmu_core, :trams_dispute_window_days, 120   # fallback default (Visa/MC)

  Note: this is the *dispute-filing eligibility* window (FR-DPS-003 — how long after
  the transaction a dispute may be opened at all) — distinct from
  `dps.provisional_credit_window_days` (how quickly provisional credit must be posted
  *after* filing), which is wired into `VmuCore.DPS.Dispute` instead. Do not conflate
  the two.

  The window is looked up per network + reason code from `VmuCore.DPS.ReasonCode`
  (FR-DPS-004 reference data, `priv/repo/seed_dps_reason_codes.exs`) — the app-env
  value above is only the fallback when a code isn't in that table.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, EventStore}
  alias VmuCore.DPS.{Dispute, ReasonCode}

  @disputable_states ~w[POSTED STATEMENTED PAID]

  @doc """
  File a dispute against a TRAM transaction.

  Attrs: `:reason_code` (network reason code), optional `:network` ("MC"/"VI",
  default "MC"), optional `:dispute_amount` (defaults to the settled amount),
  optional `:narrative`.

  Returns `{:ok, dispute, transaction}` or `{:error, reason}`.
  """
  @spec file_dispute(Ecto.UUID.t(), map()) ::
          {:ok, Dispute.t(), Transaction.t()} | {:error, term()}
  def file_dispute(transaction_id, attrs) do
    network     = attrs[:network] || "MC"
    reason_code = Map.fetch!(attrs, :reason_code)

    with {:ok, txn} <- fetch_disputable(transaction_id),
         :ok        <- check_dispute_window(txn, network, reason_code) do
      dispute_attrs = %{
        account_id:           txn.account_id,
        trams_transaction_id: txn.transaction_id,
        transaction_date:     txn_date(txn),
        dispute_amount:       attrs[:dispute_amount] || txn.settled_amount || txn.amount,
        currency:             txn.currency || "AED",
        reason_code:          reason_code,
        network:              network
      }

      case Dispute.file(dispute_attrs) do
        {:ok, dispute} ->
          case EventStore.append(txn.transaction_id, "dispute_created", %{
                 dispute_id:  dispute.dispute_id,
                 reason_code: dispute.reason_code,
                 amount:      dispute.dispute_amount,
                 network:     dispute.network
               }, actor: attrs[:actor] || "cardholder") do
            {:ok, %{transaction: updated}} -> {:ok, dispute, updated}
            {:error, reason} ->
              # Dispute exists in DPS either way — surface but don't unwind
              Logger.error("[TRAMS.DisputeBridge] dispute_created rejected for " <>
                           "#{txn.transaction_id}: #{inspect(reason)}")
              {:ok, dispute, txn}
          end

        {:error, _} = err ->
          err
      end
    end
  end

  @doc """
  Mirror a DPS dispute transition into the TRAM event log. Called from
  `DPS.Dispute.transition/2` after commit — fail-safe: any error here is
  logged and swallowed, DPS state is already committed.
  """
  @spec notify_transition(Dispute.t()) :: :ok
  def notify_transition(%Dispute{trams_transaction_id: nil}), do: :ok

  def notify_transition(%Dispute{} = dispute) do
    {event_type, payload} = map_status(dispute)

    if event_type do
      case EventStore.append(dispute.trams_transaction_id, event_type, payload,
             actor: "dps") do
        {:ok, _} -> :ok
        {:error, reason} ->
          Logger.warning("[TRAMS.DisputeBridge] #{event_type} rejected for " <>
                         "#{dispute.trams_transaction_id}: #{inspect(reason)}")
      end
    end

    :ok
  rescue
    e ->
      Logger.error("[TRAMS.DisputeBridge] notify_transition crashed: #{Exception.message(e)}")
      :ok
  end

  @doc "Open dispute case (if any) for a transaction — Inquiry detail view."
  @spec dispute_for_transaction(Ecto.UUID.t()) :: Dispute.t() | nil
  def dispute_for_transaction(transaction_id) do
    Repo.one(
      from d in Dispute,
        where: d.trams_transaction_id == ^transaction_id,
        order_by: [desc: d.inserted_at],
        limit: 1
    )
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp fetch_disputable(transaction_id) do
    case Repo.get(Transaction, transaction_id) do
      nil ->
        {:error, :transaction_not_found}

      %Transaction{state: state} = txn when state in @disputable_states ->
        {:ok, txn}

      %Transaction{state: state} ->
        {:error, {:not_disputable, state}}
    end
  end

  defp check_dispute_window(txn, network, reason_code) do
    default_days = Application.get_env(:vmu_core, :trams_dispute_window_days, 120)
    window_days  = ReasonCode.window_days(network, reason_code, default_days)
    txn_date     = txn_date(txn)

    if Date.diff(Date.utc_today(), txn_date) <= window_days do
      :ok
    else
      {:error, {:dispute_window_expired, txn_date, window_days}}
    end
  end

  defp txn_date(%Transaction{transaction_date: %DateTime{} = dt}), do: DateTime.to_date(dt)
  defp txn_date(%Transaction{} = txn), do: DateTime.to_date(txn.inserted_at)

  defp map_status(%Dispute{status: status} = d) do
    base = %{dispute_id: d.dispute_id, dps_status: status}

    case status do
      "CHARGEBACK_FILED" -> {"chargeback_created", Map.put(base, :amount, d.dispute_amount)}
      "CLOSED_WIN"       -> {"dispute_resolved", Map.put(base, :outcome, "cardholder_won")}
      "CLOSED_LOSE"      -> {"chargeback_reversed", Map.put(base, :outcome, "merchant_won")}
      "CANCELLED"        -> {"dispute_resolved", Map.put(base, :outcome, "cancelled")}
      s when s in ~w[RETRIEVAL_REQUESTED REPRESENTED PRE_ARB ARBITRATION] ->
        {"dispute_stage_changed", base}
      _ ->
        {nil, base}
    end
  end
end
