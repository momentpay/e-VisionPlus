defmodule VmuCore.CMS.PrepaidLedger do
  @moduledoc """
  Stored-value ledger operations for `PrepaidAccount` (Way4 parity plan
  Phase 1 item 5, P1). `balance/1` is always derived (sum of active,
  unexpired LOAD rows' `remaining_amount`) — never a stored counter, so
  it can never drift from ledger truth (the real LMS-P1 bug this
  session's own `LMS.PointsLedger` precedent was built to avoid).

  `spend/3` consumes ACTIVE LOAD rows soonest-expiring-first (FIFO by
  `expiry_date`, nulls last) — the standard stored-value dormancy
  convention: value that's about to expire gets spent before value that
  isn't. `credit/1` (reversal) restores exactly the loads a given SPEND
  drew from, recorded on the SPEND row itself.
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.PrepaidAccount, CMS.PrepaidLedgerEntry, CMS.InternalGlPoster}
  alias Decimal, as: D

  # LOAD and REFUND rows are both "consumable value" — a REFUND (from
  # `refund/2`, a generic reversal without a precise spend to reverse)
  # is spendable value the same as an original load, just distinct in
  # the audit trail for where it came from. ADJUSTMENT added 2026-07-28
  # (Card Products UX Parity Phase 2c) — a CREDIT-direction manual
  # adjustment (`PrepaidAdjustmentCommand`) inserts an ACTIVE ADJUSTMENT
  # row exactly like a LOAD; it must count toward balance and be
  # spendable the same way.
  @consumable_entry_types ["LOAD", "REFUND", "ADJUSTMENT"]

  @doc "Sum of remaining_amount across ACTIVE, unexpired LOAD/REFUND rows."
  @spec balance(Ecto.UUID.t()) :: Decimal.t()
  def balance(prepaid_account_id) do
    from(l in PrepaidLedgerEntry,
      where: l.prepaid_account_id == ^prepaid_account_id
        and l.entry_type in ^@consumable_entry_types and l.status == "ACTIVE",
      select: coalesce(sum(l.remaining_amount), 0))
    |> Repo.one()
  end

  @doc """
  Loads value into a prepaid account and posts the funding-side GL entry
  in the same transaction (same real-time-GL convention `CMS.
  DebitFundingCommand.fund/1` already uses for Debit's D2).

  attrs = %{prepaid_account_id:, amount:, channel:, posted_by:,
            external_reference: (required for external channels),
            expiry_date: (optional — nil means this load never expires),
            idempotency_key: (optional — see below)}

  ## Idempotency

  Pass `:idempotency_key` and a replay returns `{:error, :duplicate}` instead of
  loading again. Without one a fresh key is generated per call, which means the
  call is **not** idempotent — two invocations create two loads.

  That default is safe for an interactive top-up, where the operator is the
  retry mechanism, and unsafe for anything batch. `WPS.Disbursement` derives its
  key from the employer's payment reference for exactly this reason: a re-run of
  a salary batch must not pay every worker twice.

  Added 2026-08-06 (WPS W3). `spend/3` already took a key; `load/1` did not,
  which was the wrong way round — a duplicate spend is recoverable, a duplicate
  load creates money.
  """
  def load(attrs) do
    account = Repo.get(PrepaidAccount, attrs.prepaid_account_id)

    if is_nil(account) or not PrepaidAccount.active?(account) do
      {:error, :prepaid_account_not_active}
    else
      idempotency_key =
        Map.get(attrs, :idempotency_key) ||
          "prepaid_load:#{attrs.prepaid_account_id}:#{System.unique_integer([:positive])}"

      Repo.transaction(fn ->
        with {:ok, gl_entry} <-
               InternalGlPoster.post_prepaid_load(
                 attrs.prepaid_account_id, attrs.amount, Date.utc_today(), attrs.channel, idempotency_key
               ),
             {:ok, load_entry} <-
               %PrepaidLedgerEntry{}
               |> PrepaidLedgerEntry.changeset(Map.merge(attrs, %{
                 entry_type: "LOAD", remaining_amount: attrs.amount, status: "ACTIVE",
                 posting_date: Date.utc_today(), idempotency_key: gl_entry.posting_set.idempotency_key <> ":ledger"
               }))
               |> Repo.insert() do
          %{load_entry: load_entry, ledger_gl_entry: gl_entry}
        else
          {:error, reason} -> Repo.rollback(reason)
        end
      end)
    end
  end

  @doc """
  Spends `amount` against an account's ACTIVE, unexpired loads
  (soonest-expiring first). Returns `{:ok, spend_entry}` or
  `{:error, :insufficient_funds | :not_found | :not_active}`.

  Opts: `:posted_by` (default `"system"`), `:posting_date` (default
  today), `:idempotency_key`.
  """
  @spec spend(Ecto.UUID.t(), Decimal.t(), keyword()) ::
          {:ok, PrepaidLedgerEntry.t()} | {:error, term()}
  def spend(prepaid_account_id, amount, opts \\ []) do
    case Repo.get(PrepaidAccount, prepaid_account_id) do
      nil ->
        {:error, :not_found}

      %PrepaidAccount{} = account ->
        if not PrepaidAccount.active?(account) do
          {:error, :not_active}
        else
          Repo.transaction(fn ->
            case consume_active_loads(prepaid_account_id, amount) do
              {:ok, consumed} ->
                %PrepaidLedgerEntry{}
                |> PrepaidLedgerEntry.changeset(%{
                  prepaid_account_id: prepaid_account_id, entry_type: "SPEND", amount: amount,
                  consumed_from: Enum.map(consumed, fn %{load_entry_id: id, amount: amt} ->
                    %{"load_entry_id" => id, "amount" => D.to_string(amt)}
                  end),
                  posted_by: Keyword.get(opts, :posted_by, "system"),
                  posting_date: Keyword.get(opts, :posting_date, Date.utc_today()),
                  idempotency_key: Keyword.get(opts, :idempotency_key)
                })
                |> Repo.insert()
                |> case do
                  {:ok, entry} -> entry
                  {:error, reason} -> Repo.rollback(reason)
                end

              {:error, :insufficient_funds} ->
                Repo.rollback(:insufficient_funds)
            end
          end)
        end
    end
  end

  @doc """
  Reverses a `SPEND` entry — restores exactly the load rows (and
  amounts) it drew from, via its own `consumed_from` breakdown. Never
  guesses which load(s) to credit back.
  """
  @spec credit(Ecto.UUID.t()) :: :ok | {:error, :not_found | :not_a_spend_entry}
  def credit(spend_entry_id) do
    case Repo.get(PrepaidLedgerEntry, spend_entry_id) do
      nil ->
        {:error, :not_found}

      %PrepaidLedgerEntry{entry_type: "SPEND", consumed_from: consumed_from} ->
        Enum.each(consumed_from || [], fn %{"load_entry_id" => id, "amount" => amt_str} ->
          Repo.update_all(
            from(l in PrepaidLedgerEntry, where: l.id == ^id),
            inc: [remaining_amount: D.new(amt_str)]
          )
        end)

        :ok

      %PrepaidLedgerEntry{} ->
        {:error, :not_a_spend_entry}
    end
  end

  @doc """
  True if `id` resolves to a `PrepaidAccount` — used by shared
  touchpoints (`TRAMS.Oban.AuthExpirySweepJob`, `FAS.ReversalHandler`)
  that need to branch between restoring OTB (credit), `available_balance`
  (Debit), or the stored-value ledger (Prepaid) for the same generic
  `fas_pending_holds.account_id`. Mirrors `CMS.DebitAuthorization.
  debit_account?/1`.
  """
  @spec prepaid_account?(Ecto.UUID.t()) :: boolean()
  def prepaid_account?(id), do: not is_nil(Repo.get(PrepaidAccount, id))

  @doc """
  Restores `amount` to a prepaid account WITHOUT a specific `SPEND` entry
  to reverse precisely — for generic reversal/expiry touchpoints (0400
  reversal, `AuthExpirySweepJob`) that only have an `account_id`+`amount`,
  not the original spend's `consumed_from` breakdown. Inserts a `REFUND`
  LOAD row (its own `remaining_amount`, no expiry) rather than guessing
  which original load to credit back — correct in aggregate (the
  balance increases by exactly the right amount) and honestly distinct
  in the audit trail from `credit/1`'s precise, spend-specific reversal.
  """
  @spec refund(Ecto.UUID.t(), Decimal.t()) :: {:ok, PrepaidLedgerEntry.t()} | {:error, term()}
  def refund(prepaid_account_id, amount) do
    %PrepaidLedgerEntry{}
    |> PrepaidLedgerEntry.changeset(%{
      prepaid_account_id: prepaid_account_id, entry_type: "REFUND", amount: amount,
      remaining_amount: amount, status: "ACTIVE",
      posted_by: "system", posting_date: Date.utc_today()
    })
    |> Repo.insert()
  end

  @doc """
  Selects and decrements `amount` worth of ACTIVE, unexpired loads
  (soonest-expiring first, `FOR UPDATE` locked) — the shared consumption
  step both `spend/3` and `PrepaidAdjustmentCommand`'s DEBIT direction
  use, each inserting their own ledger row (`SPEND` vs. `ADJUSTMENT`)
  with the returned `consumed_from` breakdown. Must be called inside an
  existing `Repo.transaction/1`. Returns `{:ok, consumed}` (a list of
  `%{load_entry_id:, amount:}`) or `{:error, :insufficient_funds}` — on
  the error path nothing is decremented.
  """
  @spec consume_active_loads(Ecto.UUID.t(), Decimal.t()) ::
          {:ok, [%{load_entry_id: Ecto.UUID.t(), amount: Decimal.t()}]} | {:error, :insufficient_funds}
  def consume_active_loads(prepaid_account_id, amount) do
    loads =
      Repo.all(
        from l in PrepaidLedgerEntry,
          where: l.prepaid_account_id == ^prepaid_account_id
            and l.entry_type in ^@consumable_entry_types
            and l.status == "ACTIVE" and l.remaining_amount > 0,
          order_by: [asc_nulls_last: l.expiry_date, asc: l.inserted_at],
          lock: "FOR UPDATE"
      )

    case consume_loads(loads, amount) do
      {:ok, consumed} ->
        Enum.each(consumed, fn %{load_entry_id: id, amount: amt} ->
          Repo.update_all(
            from(l in PrepaidLedgerEntry, where: l.id == ^id),
            inc: [remaining_amount: D.negate(amt)]
          )
        end)

        {:ok, consumed}

      {:error, :insufficient_funds} ->
        {:error, :insufficient_funds}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp consume_loads(loads, remaining_needed, acc \\ [])

  defp consume_loads(loads, remaining_needed, acc) do
    if D.compare(remaining_needed, D.new(0)) != :gt do
      {:ok, Enum.reverse(acc)}
    else
      case loads do
        [] ->
          {:error, :insufficient_funds}

        [load | rest] ->
          take =
            if D.compare(load.remaining_amount, remaining_needed) == :lt,
              do: load.remaining_amount,
              else: remaining_needed

          consume_loads(rest, D.sub(remaining_needed, take), [%{load_entry_id: load.id, amount: take} | acc])
      end
    end
  end
end
