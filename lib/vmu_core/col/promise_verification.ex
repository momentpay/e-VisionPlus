defmodule VmuCore.COL.PromiseVerification do
  @moduledoc """
  Promise-to-pay auto-verification (COL-P7, FR-COL-006b).

  A promise is logged via `log_promise/3` (case status → `PROMISED`,
  `promise_status` → `"PENDING"`, `promise_logged_at` stamped as the baseline
  for "payments received since the promise was made" — deliberately tracked
  as its own timestamp rather than reusing `updated_at`, since that column
  bumps on unrelated case changes too).

  `verify_case/2` is called once per day, per open-promise case, from
  `CMS.EOD.AgeBucketsJob` (the same daily cadence everything else in COL rides
  on):

  - Promise date not yet reached → still `PENDING`, no-op.
  - Promise date reached: sums `PAYMENT` ledger entries posted between
    `promise_logged_at` and `promise_date` (inclusive). >= `promise_amount` →
    `KEPT`; otherwise → `BROKEN`. Either way the case returns to `OPEN` so the
    normal collection cycle (queue routing, dunning, write-off threshold)
    picks it back up on the next run — a broken promise doesn't get any
    special escalation beyond that; a kept one doesn't get auto-closed
    (FR-COL-009 cure detection is a separate, still-open gap).
  """

  require Logger

  alias VmuCore.COL.CollectionCase
  alias Decimal, as: D

  # M2 (2026-07-17): config-injected — CMS isn't extracted yet.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)

  alias VmuCore.GL.LedgerQuery

  @doc "Log a promise-to-pay against a case: status → PROMISED, promise_status → PENDING."
  @spec log_promise(Ecto.UUID.t(), Decimal.t(), Date.t()) ::
          {:ok, CollectionCase.t()} | {:error, term()}
  def log_promise(case_id, promise_amount, promise_date) do
    case @repo.get(CollectionCase, case_id) do
      nil ->
        {:error, :case_not_found}

      case_row ->
        case_row
        |> CollectionCase.changeset(%{
          status: "PROMISED",
          promise_amount: promise_amount,
          promise_date: promise_date,
          promise_status: "PENDING",
          promise_logged_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> @repo.update()
    end
  end

  @doc """
  Verify a case's pending promise as of `as_of_date`. No-op (returns `:pending`)
  if the case isn't a pending promise, or the promise date hasn't arrived yet.
  """
  @spec verify_case(CollectionCase.t(), Date.t()) ::
          {:ok, :kept | :broken} | :pending | :not_applicable
  def verify_case(%CollectionCase{status: "PROMISED", promise_status: "PENDING"} = case_row, as_of_date) do
    cond do
      is_nil(case_row.promise_date) or Date.compare(case_row.promise_date, as_of_date) == :gt ->
        :pending

      true ->
        paid = payments_since(case_row.account_id, case_row.promise_logged_at, case_row.promise_date)

        {outcome_atom, outcome_str} =
          if D.compare(paid, case_row.promise_amount) != :lt,
            do: {:kept, "KEPT"},
            else: {:broken, "BROKEN"}

        case_row
        |> CollectionCase.changeset(%{status: "OPEN", promise_status: outcome_str})
        |> @repo.update!()

        Logger.warning("[COL] Promise #{outcome_str}: case=#{case_row.case_id} account=#{case_row.account_id} " <>
                        "promised=#{case_row.promise_amount} paid=#{paid}")

        {:ok, outcome_atom}
    end
  end

  def verify_case(%CollectionCase{}, _as_of_date), do: :not_applicable

  defp payments_since(account_id, nil, promise_date) do
    payments_since(account_id, DateTime.new!(~D[1970-01-01], ~T[00:00:00]), promise_date)
  end

  # GL Phase C2 — see `GL.LedgerQuery`. This drops the `@ledger_entry_schema`
  # injection seam, which no config ever set: the only value it could take was
  # its own default.
  defp payments_since(account_id, since_datetime, promise_date) do
    LedgerQuery.sum_amount(
      account_ref: account_id,
      transaction_code: "PAYMENT",
      from: DateTime.to_date(since_datetime),
      to: promise_date
    )
  end
end
