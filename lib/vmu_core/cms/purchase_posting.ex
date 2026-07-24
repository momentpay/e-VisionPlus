defmodule VmuCore.CMS.PurchasePosting do
  @moduledoc """
  Closes a real, pre-existing gap found live 2026-07-24 building FR-067: a
  purchase/cash-advance transaction reaching TRAM's POSTED state never
  actually incremented `VmuCore.CMS.BalanceBucket` anywhere in this
  codebase. `FAS.SettlementPostingAdapter.do_confirm/3` posts a real GL
  entry (via `WalletGl.GlPostingRecord`/`VmuCoreGlAdapter`) and clears the
  FAS hold, but nothing propagated that into the balance number
  `RepaymentDistributor`/interest accrual/statement generation actually
  read from — accounts with real purchase activity would never show it as
  outstanding balance.

  `post/1`, called from inside `SettlementPostingAdapter.do_confirm/3`'s
  own transaction (atomic with the GL post — both commit or both roll
  back), does the two things that were missing:

  1. Creates a `VmuCore.CMS.TransactionAllocation` row (FR-067's
     transaction-level detail — `original_amount`/`remaining_amount`,
     `OUTSTANDING`).
  2. Increments the account's current `BalanceBucket.bucket_field` by the
     same amount, keeping the fast-read aggregate in sync with the
     transaction-level detail (dual-write, both sides always move
     together — never derive one from the other on the hot path).

  Idempotent via `idempotency_key` (reuses the same
  `"settlement:<approval_code>:<rrn>"` key `SettlementPostingAdapter`
  already uses for its own GL idempotency — one key, one meaning, across
  both tables).

  ## Deliberately NOT included: historical backfill

  This fixes the pipeline going forward only. Accounts with real purchase
  activity already posted through the old (incomplete) path have
  `BalanceBucket` totals that understate their true outstanding balance —
  a real, standing data-quality issue. Backfilling live financial balances
  automatically is exactly the kind of change that must be deliberate,
  reviewed, and reconciled by hand, not something this pass does as a side
  effect. Flagged in `CMS_Feature_Status.md` FR-067, not silently left
  for someone to discover later.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.TransactionAllocation}
  alias Decimal, as: D

  @doc """
  Post a purchase/cash-advance. `attrs`:
    - `:account_id` (required)
    - `:amount` (required, Decimal, > 0)
    - `:idempotency_key` (required — same key the caller's GL post used)
    - `:transaction_date` (required, Date)
    - `:bucket_field` (optional, default `"retail_balance"` — pass
      `"cash_balance"` for a cash-advance transaction)
    - `:trams_transaction_id` (optional)

  Returns `{:ok, %TransactionAllocation{}}` (already-posted is a no-op
  `{:ok, existing}`, not an error — same idempotency posture as
  `InternalGlPoster.post/1`) or `{:error, reason}`.
  """
  @spec post(map()) :: {:ok, TransactionAllocation.t()} | {:error, term()}
  def post(%{account_id: account_id, amount: %D{} = amount, idempotency_key: key, transaction_date: date} = attrs) do
    bucket_field = Map.get(attrs, :bucket_field, "retail_balance")

    case Repo.get_by(TransactionAllocation, idempotency_key: key) do
      %TransactionAllocation{} = existing ->
        Logger.debug("[PurchasePosting] Already posted: #{key}")
        {:ok, existing}

      nil ->
        do_post(account_id, amount, bucket_field, date, Map.get(attrs, :trams_transaction_id), key)
    end
  end

  defp do_post(account_id, amount, bucket_field, date, trams_transaction_id, key) do
    with %Account{} <- Repo.get(Account, account_id) || {:error, :account_not_found},
         %BalanceBucket{} = bucket <- latest_bucket(account_id) || {:error, :no_balance_bucket} do
      Repo.transaction(fn ->
        allocation =
          %TransactionAllocation{}
          |> TransactionAllocation.changeset(%{
            account_id: account_id,
            trams_transaction_id: trams_transaction_id,
            bucket_field: bucket_field,
            original_amount: amount,
            remaining_amount: amount,
            transaction_date: date,
            idempotency_key: key
          })
          |> Repo.insert()

        case allocation do
          {:ok, row} ->
            increment_bucket(bucket, bucket_field, amount)
            row

          {:error, changeset} ->
            Repo.rollback(changeset)
        end
      end)
    end
  end

  defp increment_bucket(bucket, field, amount) do
    field_atom = String.to_existing_atom(field)
    current = Map.get(bucket, field_atom) || D.new(0)

    Repo.update_all(
      from(b in BalanceBucket, where: b.bucket_id == ^bucket.bucket_id),
      set: [{field_atom, D.add(current, amount)}, {:updated_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)}]
    )
  end

  defp latest_bucket(account_id) do
    Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id,
        order_by: [desc: b.balance_date],
        limit: 1
    )
  end
end
