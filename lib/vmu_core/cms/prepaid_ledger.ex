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

  @doc "Sum of remaining_amount across ACTIVE, unexpired LOAD rows."
  @spec balance(Ecto.UUID.t()) :: Decimal.t()
  def balance(prepaid_account_id) do
    from(l in PrepaidLedgerEntry,
      where: l.prepaid_account_id == ^prepaid_account_id and l.entry_type == "LOAD"
        and l.status == "ACTIVE",
      select: coalesce(sum(l.remaining_amount), 0))
    |> Repo.one()
  end

  @doc """
  Loads value into a prepaid account and posts the funding-side GL entry
  in the same transaction (same real-time-GL convention `CMS.
  DebitFundingCommand.fund/1` already uses for Debit's D2).

  attrs = %{prepaid_account_id:, amount:, channel:, posted_by:,
            external_reference: (required for external channels),
            expiry_date: (optional — nil means this load never expires)}
  """
  def load(attrs) do
    account = Repo.get(PrepaidAccount, attrs.prepaid_account_id)

    if is_nil(account) or not PrepaidAccount.active?(account) do
      {:error, :prepaid_account_not_active}
    else
      idempotency_key = "prepaid_load:#{attrs.prepaid_account_id}:#{System.unique_integer([:positive])}"

      Repo.transaction(fn ->
        with {:ok, gl_entry} <-
               InternalGlPoster.post_prepaid_load(
                 attrs.prepaid_account_id, attrs.amount, Date.utc_today(), attrs.channel, idempotency_key
               ),
             {:ok, load_entry} <-
               %PrepaidLedgerEntry{}
               |> PrepaidLedgerEntry.changeset(Map.merge(attrs, %{
                 entry_type: "LOAD", remaining_amount: attrs.amount, status: "ACTIVE",
                 posting_date: Date.utc_today(), idempotency_key: gl_entry.idempotency_key <> ":ledger"
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
            loads =
              Repo.all(
                from l in PrepaidLedgerEntry,
                  where: l.prepaid_account_id == ^prepaid_account_id and l.entry_type == "LOAD"
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
