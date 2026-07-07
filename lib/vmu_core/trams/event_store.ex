defmodule VmuCore.TRAMS.EventStore do
  @moduledoc """
  The only write path into the TRAM event log (TRAM-P1 1E).

  Guarantees, per append:
  - the transaction row is locked (`FOR UPDATE`) so concurrent appends
    serialize and `seq` is gapless per transaction
  - the state transition is validated by `VmuCore.TRAMS.StateMachine`
  - the event insert and the state-projection update commit atomically

  `state` on `trams_transactions` is a projection (ADR-T1): correct by
  construction because it only changes here, in the same DB transaction as
  the event that justifies it.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, TransactionEvent, TransactionIdentifier, StateMachine}

  @doc """
  Open a new transaction with its first event, idempotently keyed on
  `fas_authorization_id`. If a transaction already exists for that auth
  record, returns it unchanged — safe against FAS retry/duplicate delivery
  (spec 10 §2.1).

  Returns `{:ok, transaction}` or `{:error, reason}`.
  """
  @spec open(map(), String.t(), map()) :: {:ok, Transaction.t()} | {:error, term()}
  def open(attrs, first_event_type, payload \\ %{}) do
    case Repo.get_by(Transaction, fas_authorization_id: attrs[:fas_authorization_id]) do
      %Transaction{} = existing ->
        {:ok, existing}

      nil ->
        insert_new(attrs, first_event_type, payload)
    end
  end

  @doc """
  Append an event to an existing transaction, validating the lifecycle
  transition and updating the state projection atomically.

  Options:
    - `:actor`       — "system" (default), "network", or an operator ID
    - `:occurred_at` — event time; defaults to now

  Returns `{:ok, %{transaction: txn, event: event}}` or
  `{:error, {:invalid_transition, current_state, event_type}}` /
  `{:error, :not_found}`.
  """
  @spec append(Ecto.UUID.t(), String.t(), map(), keyword()) ::
          {:ok, %{transaction: Transaction.t(), event: TransactionEvent.t()}}
          | {:error, term()}
  def append(transaction_id, event_type, payload \\ %{}, opts \\ []) do
    Repo.transaction(fn ->
      txn =
        Repo.one(
          from t in Transaction,
            where: t.transaction_id == ^transaction_id,
            lock: "FOR UPDATE"
        )

      if is_nil(txn), do: Repo.rollback(:not_found)

      case StateMachine.apply_event(txn.state, event_type) do
        {:ok, new_state} ->
          event = insert_event!(transaction_id, event_type, payload, opts)
          txn   = maybe_update_state(txn, new_state, event_type)
          VmuCore.TRAMS.Telemetry.execute_event(event_type, new_state)
          %{transaction: txn, event: event}

        {:error, reason} ->
          Logger.warning("[TRAMS.EventStore] Rejected #{event_type} on " <>
                         "#{transaction_id} in state #{txn.state}: #{reason}")
          Repo.rollback({reason, txn.state, event_type})
      end
    end)
  end

  @doc "Find a transaction by the FAS authorization record it originated from."
  @spec by_fas_authorization(Ecto.UUID.t()) :: Transaction.t() | nil
  def by_fas_authorization(fas_authorization_id) do
    Repo.get_by(Transaction, fas_authorization_id: fas_authorization_id)
  end

  @doc "Full ordered event history for a transaction."
  @spec history(Ecto.UUID.t()) :: [TransactionEvent.t()]
  def history(transaction_id) do
    Repo.all(
      from e in TransactionEvent,
        where: e.transaction_id == ^transaction_id,
        order_by: [asc: e.seq]
    )
  end

  @doc """
  Record an external-identifier row for a transaction (STAN/RRN/auth code —
  spec Section 6.3). Additive; a transaction accumulates one row per source
  message.
  """
  @spec add_identifier(Ecto.UUID.t(), map()) ::
          {:ok, TransactionIdentifier.t()} | {:error, Ecto.Changeset.t()}
  def add_identifier(transaction_id, attrs) do
    %TransactionIdentifier{}
    |> TransactionIdentifier.changeset(Map.put(attrs, :transaction_id, transaction_id))
    |> Repo.insert()
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp insert_new(attrs, first_event_type, payload) do
    result =
      Repo.transaction(fn ->
        txn =
          %Transaction{}
          |> Transaction.changeset(Map.put(attrs, :state, "INITIATED"))
          |> Repo.insert!()

        case StateMachine.apply_event("INITIATED", first_event_type) do
          {:ok, new_state} ->
            insert_event!(txn.transaction_id, first_event_type, payload, [])
            maybe_update_state(txn, new_state, first_event_type)

          {:error, reason} ->
            Repo.rollback({reason, "INITIATED", first_event_type})
        end
      end)

    case result do
      {:ok, txn} -> {:ok, txn}
      {:error, _} = err -> handle_insert_error(err, attrs)
    end
  rescue
    e in Ecto.ConstraintError ->
      # Lost a race on the fas_authorization_id unique index — fetch the winner
      if e.constraint =~ "fas_authorization_id" do
        {:ok, Repo.get_by!(Transaction, fas_authorization_id: attrs[:fas_authorization_id])}
      else
        {:error, e}
      end
  end

  defp handle_insert_error({:error, reason} = err, attrs) do
    Logger.error("[TRAMS.EventStore] open failed for auth " <>
                 "#{inspect(attrs[:fas_authorization_id])}: #{inspect(reason)}")
    err
  end

  defp insert_event!(transaction_id, event_type, payload, opts) do
    seq = next_seq(transaction_id)

    %TransactionEvent{}
    |> TransactionEvent.changeset(%{
      transaction_id: transaction_id,
      seq:            seq,
      event_type:     event_type,
      payload:        json_safe(payload),
      actor:          Keyword.get(opts, :actor, "system"),
      occurred_at:    Keyword.get(opts, :occurred_at, DateTime.utc_now())
    })
    |> Repo.insert!()
  end

  defp next_seq(transaction_id) do
    (Repo.one(
       from e in TransactionEvent,
         where: e.transaction_id == ^transaction_id,
         select: max(e.seq)
     ) || 0) + 1
  end

  defp maybe_update_state(txn, new_state, _event_type) when txn.state == new_state, do: txn

  defp maybe_update_state(txn, new_state, event_type) do
    changes =
      %{state: new_state}
      |> maybe_stamp(:posted_at, event_type == "transaction_posted")
      |> maybe_stamp(:closed_at, new_state == "CLOSED")

    txn
    |> Ecto.Changeset.change(changes)
    |> Repo.update!()
  end

  defp maybe_stamp(changes, _key, false), do: changes
  defp maybe_stamp(changes, key, true) do
    Map.put(changes, key, DateTime.utc_now() |> DateTime.truncate(:second))
  end

  # JSONB payloads must have string keys and JSON-safe values — ISO field maps
  # arrive with integer keys, and Decimal/DateTime need string coercion.
  defp json_safe(payload) when is_map(payload) do
    Map.new(payload, fn {k, v} -> {to_string(k), json_safe_value(v)} end)
  end

  defp json_safe_value(%Decimal{} = d),       do: Decimal.to_string(d)
  defp json_safe_value(%DateTime{} = t),      do: DateTime.to_iso8601(t)
  defp json_safe_value(%Date{} = d),          do: Date.to_iso8601(d)
  defp json_safe_value(%NaiveDateTime{} = t), do: NaiveDateTime.to_iso8601(t)
  defp json_safe_value(%_{} = struct),        do: inspect(struct)
  defp json_safe_value(v) when is_map(v),     do: json_safe(v)
  defp json_safe_value(v) when is_list(v), do: Enum.map(v, &json_safe_value/1)
  defp json_safe_value(v) when is_binary(v) or is_number(v) or is_boolean(v) or is_nil(v), do: v
  defp json_safe_value(v), do: inspect(v)
end
