defmodule VmuCore.TRAMS.StatementExtraction do
  @moduledoc """
  Statement cutoff extraction (TRAM-P5 5A, spec 07).

  Produces the definitive per-line transaction set for an account's billing
  cycle and hands it to Billing. Called per account from the CMS EOD pipeline
  (`GenerateStatementJob`, TRAM-P5 5B) — the EOD scheduler already fans out
  per due cycle_code, so this runs against the subset of accounts due that
  day (spec 09 §2.4).

  ## Cutoff rules (spec 07 §2.1)

  - Transactions in POSTED at cutoff and never statemented → become lines on
    THIS statement and transition to STATEMENTED.
  - Transactions still AUTHORIZED/CLEARED at cutoff → roll to the next cycle
    (untouched here).
  - Adjustments posted after a transaction was already statemented → appear
    as their own ADJUSTMENT_CREDIT/DEBIT line on THIS cycle, never as edits
    to a past statement. Multiple same-direction adjustments to one
    transaction within the window collapse into one summed line (the unique
    (transaction_id, statement_date, line_type) key also makes re-runs
    idempotent).

  ## Regeneration (spec 07 §2.4)

  Lines are persisted per cycle, so reprinting a past statement is a pure
  read (`lines_for_cycle/2`) — no replay needed.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.TRAMS.{Transaction, TransactionIdentifier, StatementLine, Adjustment, EventStore}

  @doc """
  Extract statementable lines for `account_id` at `statement_date` cutoff.

  Options:
    - `:cycle_start` — start of the billing window for late-adjustment pickup
      (defaults to statement_date - 31 days)

  Returns `{:ok, %{lines: n, statemented: n, adjustment_lines: n}}`.
  Idempotent: re-running for the same cycle inserts nothing new.
  """
  @spec extract(Ecto.UUID.t(), Date.t(), keyword()) :: {:ok, map()}
  def extract(account_id, statement_date, opts \\ []) do
    cycle_start = Keyword.get(opts, :cycle_start, Date.add(statement_date, -31))

    posted = unstatemented_posted(account_id)

    statemented =
      Enum.count(posted, fn txn ->
        case emit_line_and_statement(txn, statement_date) do
          :ok -> true
          :error -> false
        end
      end)

    adjustment_lines = emit_late_adjustment_lines(account_id, statement_date, cycle_start)

    Logger.info("[TRAMS.StatementExtraction] account=#{account_id} " <>
                "date=#{statement_date} statemented=#{statemented} " <>
                "adjustment_lines=#{adjustment_lines}")

    {:ok, %{lines: statemented + adjustment_lines,
            statemented: statemented,
            adjustment_lines: adjustment_lines}}
  end

  @doc "All persisted lines for an account's cycle — statement rendering / reprint."
  @spec lines_for_cycle(Ecto.UUID.t(), Date.t()) :: [StatementLine.t()]
  def lines_for_cycle(account_id, statement_date) do
    Repo.all(
      from l in StatementLine,
        where: l.account_id == ^account_id and l.statement_date == ^statement_date,
        order_by: [asc: l.posting_date, asc: l.inserted_at]
    )
  end

  # ---------------------------------------------------------------------------
  # Posted → statemented
  # ---------------------------------------------------------------------------

  defp unstatemented_posted(account_id) do
    Repo.all(
      from t in Transaction,
        where: t.account_id == ^account_id
           and t.state == "POSTED"
           and is_nil(t.statement_date),
        order_by: [asc: t.posted_at]
    )
  end

  defp emit_line_and_statement(txn, statement_date) do
    line_attrs = %{
      transaction_id:   txn.transaction_id,
      account_id:       txn.account_id,
      statement_date:   statement_date,
      line_type:        line_type(txn.transaction_type),
      transaction_date: txn.transaction_date && DateTime.to_date(txn.transaction_date),
      posting_date:     txn.posted_at && DateTime.to_date(txn.posted_at),
      merchant_name:    txn.merchant_name || txn.merchant_id,
      mcc:              txn.mcc,
      amount:           txn.settled_amount || txn.amount,
      currency:         txn.currency,
      reference:        primary_rrn(txn.transaction_id)
    }

    {:ok, _} =
      Repo.transaction(fn ->
        %StatementLine{}
        |> StatementLine.changeset(line_attrs)
        |> Repo.insert!(on_conflict: :nothing,
             conflict_target: [:transaction_id, :statement_date, :line_type])

        txn
        |> Ecto.Changeset.change(statement_date: statement_date)
        |> Repo.update!()
      end)

    case EventStore.append(txn.transaction_id, "statement_generated",
           %{statement_date: statement_date}, actor: "system") do
      {:ok, _} -> :ok
      {:error, reason} ->
        Logger.warning("[TRAMS.StatementExtraction] statement_generated rejected " <>
                       "for #{txn.transaction_id}: #{inspect(reason)}")
        :ok
    end

    :ok
  rescue
    e ->
      Logger.error("[TRAMS.StatementExtraction] line failed for " <>
                   "#{txn.transaction_id}: #{Exception.message(e)}")
      :error
  end

  # ---------------------------------------------------------------------------
  # Late adjustments — own line on the CURRENT cycle (spec 06 §3.5)
  # ---------------------------------------------------------------------------

  defp emit_late_adjustment_lines(account_id, statement_date, cycle_start) do
    window_from = DateTime.new!(cycle_start, ~T[00:00:00], "Etc/UTC")
    window_to   = DateTime.new!(statement_date, ~T[23:59:59], "Etc/UTC")

    # POSTED adjustments in the window whose transaction was statemented on an
    # EARLIER cycle — freshly statemented transactions above already carry
    # their adjusted amount in the line itself.
    rows =
      Repo.all(
        from a in Adjustment,
          join: t in Transaction, on: t.transaction_id == a.transaction_id,
          where: t.account_id == ^account_id
             and a.status == "POSTED"
             and a.posted_at >= ^window_from
             and a.posted_at <= ^window_to
             and not is_nil(t.statement_date)
             and t.statement_date < ^statement_date,
          select: {a, t}
      )

    rows
    |> Enum.group_by(fn {a, t} -> {t.transaction_id, a.direction} end)
    |> Enum.count(fn {{transaction_id, direction}, group} ->
      {_, txn} = hd(group)
      total_delta = Enum.reduce(group, Decimal.new(0), fn {a, _}, acc ->
        Decimal.add(acc, Decimal.abs(a.delta))
      end)

      line_type = if direction == "CREDIT", do: "ADJUSTMENT_CREDIT", else: "ADJUSTMENT_DEBIT"

      %StatementLine{}
      |> StatementLine.changeset(%{
        transaction_id:   transaction_id,
        account_id:       account_id,
        statement_date:   statement_date,
        line_type:        line_type,
        posting_date:     statement_date,
        merchant_name:    txn.merchant_name || txn.merchant_id,
        mcc:              txn.mcc,
        amount:           total_delta,
        currency:         txn.currency,
        reference:        primary_rrn(transaction_id),
        adjustment_flag:  true
      })
      |> Repo.insert(on_conflict: :nothing,
           conflict_target: [:transaction_id, :statement_date, :line_type])
      |> case do
        {:ok, %StatementLine{id: id}} when not is_nil(id) -> true
        _ -> false
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  # RRN shown to the cardholder (dispute reference) — clearing-sourced wins
  # over authorization-sourced (spec 07 §2.3)
  defp primary_rrn(transaction_id) do
    Repo.one(
      from i in TransactionIdentifier,
        where: i.transaction_id == ^transaction_id and not is_nil(i.rrn),
        order_by: [desc: fragment("CASE WHEN ? = 'clearing' THEN 1 ELSE 0 END", i.source),
                   desc: i.inserted_at],
        select: i.rrn,
        limit: 1
    )
  end

  defp line_type("CASH_ADV"), do: "CASH_ADV"
  defp line_type("FEE"),      do: "FEE"
  defp line_type(_),          do: "PURCHASE"
end
