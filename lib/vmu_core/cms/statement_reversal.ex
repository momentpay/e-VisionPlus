defmodule VmuCore.CMS.StatementReversal do
  @moduledoc """
  Statement reversal and rebilling function.

  Used when a statement was generated incorrectly — wrong interest rate,
  incorrect fee, erroneous balance snapshot — and needs to be unwound and
  regenerated.

  ## Reversal mechanism

  A statement reversal does NOT delete ledger entries (GL entries are immutable).
  Instead it:

  1. Posts a **STATEMENT_REVERSAL** GL entry that negates the original interest
     and fee amounts posted during the billing cycle.
  2. Resets `balance_bucket.statement_balance`, `minimum_payment`, and
     `accrued_interest` to the pre-statement values on the affected bucket row.
  3. Emits a `NonMonetaryEvent` of type `cycle_change` for audit purposes.
  4. Optionally triggers a **rebill** — calls `StatementGenerator.generate/3`
     immediately so a corrected statement is produced in the same operation.

  ## Security model

  Requires 4-eyes: `operator_id` + `supervisor_id` (distinct UUIDs).

  ## Idempotency

  Idempotency key: `"STMT_REVERSAL:\#{account_id}:\#{statement_date}:\#{supervisor_id}"`

  ## Usage

      alias VmuCore.CMS.StatementReversal

      # Reverse a specific statement date
      {:ok, result} = StatementReversal.reverse(
        account_id:    acc.account_id,
        statement_date: ~D[2026-05-15],
        reason:        "Incorrect APR applied — penalty rate used on current account",
        operator_id:   agent_id,
        supervisor_id: supervisor_id
      )

      # Reverse and immediately rebill
      {:ok, result} = StatementReversal.reverse_and_rebill(
        account_id:    acc.account_id,
        statement_date: ~D[2026-05-15],
        new_apr:       Decimal.new("24.00"),
        reason:        "Penalty APR incorrectly applied",
        operator_id:   agent_id,
        supervisor_id: supervisor_id
      )
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.LedgerEntry}
  alias VmuCore.CMS.{InternalGlPoster, NonMonetaryEvent, StatementGenerator}
  alias Decimal, as: D

  @doc """
  Reverse a previously generated statement.

  Negates the interest and fee entries for the cycle ending on `statement_date`,
  resets the balance_bucket row, and records an audit event.

  ## Options (keyword list)

    - `:account_id`     — (required) target account UUID
    - `:statement_date` — (required) `Date.t()` — the cycle close date to reverse
    - `:reason`         — (required) free-text justification (max 200 chars)
    - `:operator_id`    — (required) initiating agent UUID
    - `:supervisor_id`  — (required) approving supervisor UUID (must differ from operator)

  Returns `{:ok, %{reversal_entry, updated_bucket}}` or `{:error, reason}`.
  """
  @spec reverse(keyword()) :: {:ok, map()} | {:error, term()}
  def reverse(opts) do
    with :ok <- validate_opts(opts) do
      account_id     = Keyword.fetch!(opts, :account_id)
      statement_date = Keyword.fetch!(opts, :statement_date)
      reason         = Keyword.fetch!(opts, :reason)
      operator_id    = Keyword.fetch!(opts, :operator_id)
      supervisor_id  = Keyword.fetch!(opts, :supervisor_id)

      Repo.transaction(fn ->
        bucket = fetch_statement_bucket!(account_id, statement_date)

        reversal_amount = D.add(
          bucket.accrued_interest || D.new(0),
          bucket.unpaid_fees      || D.new(0)
        )

        idempotency_key =
          "STMT_REVERSAL:#{account_id}:#{Date.to_iso8601(statement_date)}:#{supervisor_id}"

        reversal_entry =
          if D.compare(reversal_amount, D.new(0)) == :gt do
            narrative =
              "Statement reversal #{Date.to_iso8601(statement_date)} | " <>
              "op=#{String.slice(to_string(operator_id), 0, 8)} " <>
              "sup=#{String.slice(to_string(supervisor_id), 0, 8)} | #{reason}"

            case InternalGlPoster.post(%{
              account_id:       account_id,
              idempotency_key:  idempotency_key,
              transaction_code: "STATEMENT_REVERSAL",
              dr_amount:        reversal_amount,
              cr_amount:        reversal_amount,
              gl_account_dr:    "2001",   # reverse: debit income, credit receivable
              gl_account_cr:    "1003",
              posting_date:     Date.utc_today(),
              value_date:       statement_date,
              narrative:        narrative,
              source_ref:       Date.to_iso8601(statement_date)
            }) do
              {:ok, entry}        -> entry
              {:error, :duplicate} -> nil
              {:error, cs}         -> Repo.rollback(cs)
            end
          else
            nil
          end

        # Reset the balance bucket to pre-statement state
        updated_bucket =
          bucket
          |> BalanceBucket.changeset(%{
            statement_balance: D.new(0),
            minimum_payment:   D.new(0),
            accrued_interest:  D.new(0)
          })
          |> Repo.update!()

        # Record audit event
        NonMonetaryEvent.record(
          account_id:    account_id,
          event_type:    "cycle_change",
          old_value:     %{
            "statement_date"    => Date.to_iso8601(statement_date),
            "statement_balance" => Decimal.to_string(bucket.statement_balance || D.new(0)),
            "minimum_payment"   => Decimal.to_string(bucket.minimum_payment || D.new(0))
          },
          new_value:     %{"statement_balance" => "0", "minimum_payment" => "0"},
          reason:        reason,
          operator_id:   operator_id,
          operator_role: "SUPERVISOR",
          applied_at:    NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
        )

        Logger.info("[StatementReversal] account=#{account_id} date=#{statement_date} reversed #{reversal_amount}")

        %{reversal_entry: reversal_entry, updated_bucket: updated_bucket}
      end)
    end
  end

  @doc """
  Reverse a statement and immediately generate a corrected one.

  Accepts the same options as `reverse/1` plus:
    - `:new_apr`          — `Decimal.t()` — corrected APR to use for rebilling
    - `:new_min_pct`      — `Decimal.t()` — corrected minimum payment % (default: 0.05)

  Returns `{:ok, %{reversal: ..., new_statement: ...}}` or `{:error, reason}`.
  """
  @spec reverse_and_rebill(keyword()) :: {:ok, map()} | {:error, term()}
  def reverse_and_rebill(opts) do
    account_id     = Keyword.fetch!(opts, :account_id)
    statement_date = Keyword.fetch!(opts, :statement_date)
    new_apr        = Keyword.get(opts, :new_apr, D.new("24.00"))
    new_min_pct    = Keyword.get(opts, :new_min_pct, D.new("0.05"))

    with {:ok, reversal_result} <- reverse(opts),
         {:ok, new_statement}   <- StatementGenerator.generate(
                                     account_id,
                                     statement_date,
                                     apr_percentage: new_apr,
                                     min_payment_pct: new_min_pct
                                   ) do
      Logger.info("[StatementReversal] Rebilled account=#{account_id} new_balance=#{new_statement.statement_balance}")
      {:ok, %{reversal: reversal_result, new_statement: new_statement}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_opts(opts) do
    required = [:account_id, :statement_date, :reason, :operator_id, :supervisor_id]
    missing  = Enum.filter(required, &(!Keyword.has_key?(opts, &1)))

    cond do
      missing != [] ->
        {:error, {:missing_fields, missing}}

      Keyword.get(opts, :operator_id) == Keyword.get(opts, :supervisor_id) ->
        {:error, :operator_and_supervisor_must_differ}

      String.length(Keyword.get(opts, :reason, "")) > 200 ->
        {:error, :reason_too_long}

      true ->
        :ok
    end
  end

  defp fetch_statement_bucket!(account_id, statement_date) do
    case Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id
          and  b.balance_date == ^statement_date,
        limit: 1
    ) do
      nil    -> Repo.rollback({:not_found, :balance_bucket, statement_date})
      bucket -> bucket
    end
  end
end
