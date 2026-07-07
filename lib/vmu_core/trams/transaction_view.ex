defmodule VmuCore.TRAMS.TransactionView do
  @moduledoc """
  Transaction detail assembly (TRAM-P6 6B, spec 04 §2.3).

  Builds the full picture of one transaction from across the aggregate —
  "replay and display": the original authorization, all external identifiers,
  the matched clearing record, the complete event timeline, adjustments,
  statement lines, and any linked dispute case.

  Also provides the cardholder-facing status mapping (spec 04 §2.4) so
  internal state-machine vocabulary never leaks into customer copy.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, ClearingRecord, Adjustment, MaintenanceAction,
                       StatementLine, EventStore, DisputeBridge}
  alias VmuCore.FAS.AuthorizationRecord

  @cardholder_status %{
    "INITIATED"        => "Processing",
    "AUTHORIZED"       => "Pending",
    "AUTH_MAINTENANCE" => "Pending",
    "DECLINED"         => "Declined",
    "REVERSED"         => "Cancelled",
    "CLEARED"          => "Processing",
    "POSTED"           => "Completed",
    "STATEMENTED"      => "Completed",
    "PAID"             => "Completed",
    "DISPUTED"         => "Under Review",
    "CHARGEBACKED"     => "Under Review",
    "RESOLVED"         => "Resolved",
    "CLOSED"           => "Completed",
    "ARCHIVED"         => "Completed"
  }

  @doc """
  Assemble the full internal (ops/CS) detail for a transaction.

  Returns `{:ok, detail_map}` or `{:error, :not_found}`.
  """
  @spec detail(Ecto.UUID.t()) :: {:ok, map()} | {:error, :not_found}
  def detail(transaction_id) do
    case Repo.get(Transaction, transaction_id) do
      nil ->
        {:error, :not_found}

      txn ->
        {:ok,
         %{
           transaction:     txn,
           cardholder_status: cardholder_status(txn.state),
           authorization:   txn.fas_authorization_id &&
                              Repo.get(AuthorizationRecord, txn.fas_authorization_id),
           identifiers:     Repo.all(
                              from i in VmuCore.TRAMS.TransactionIdentifier,
                                where: i.transaction_id == ^transaction_id,
                                order_by: [asc: i.inserted_at]),
           clearing:        txn.clearing_id && Repo.get(ClearingRecord, txn.clearing_id),
           events:          EventStore.history(transaction_id),
           adjustments:     Repo.all(
                              from a in Adjustment,
                                where: a.transaction_id == ^transaction_id,
                                order_by: [asc: a.inserted_at]),
           maintenance:     Repo.all(
                              from m in MaintenanceAction,
                                where: m.transaction_id == ^transaction_id,
                                order_by: [asc: m.inserted_at]),
           statement_lines: Repo.all(
                              from l in StatementLine,
                                where: l.transaction_id == ^transaction_id,
                                order_by: [asc: l.statement_date]),
           dispute:         DisputeBridge.dispute_for_transaction(transaction_id)
         }}
    end
  end

  @doc "Plain-language status for cardholder-facing channels (spec 04 §2.4)."
  @spec cardholder_status(String.t()) :: String.t()
  def cardholder_status(state), do: Map.get(@cardholder_status, state, "Processing")
end
