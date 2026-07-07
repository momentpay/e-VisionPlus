defmodule VmuCore.CMS.Autopay do
  @moduledoc """
  Autopay mandate management + due-date execution (CMS-G2.2, FR-CMS-065).

  ## Due-date derivation

  Payment due = latest statement bucket's `balance_date` +
  `payment_due_days` (LOGO parameter, default 21). A mandate fires on the
  day the due date arrives, for the amount its type dictates, through the
  `direct_debit` channel with reference `"autopay:<account_id>:<due_date>"` —
  making each cycle's collection idempotent by construction (a re-run of the
  job cannot double-collect).

  FIXED mandates are capped at the statement balance (never collect more
  than is owed).
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.AutopayMandate,
                 CMS.PaymentIntake}
  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  # ---------------------------------------------------------------------------
  # Mandate management
  # ---------------------------------------------------------------------------

  @doc """
  Enroll an account. Attrs: `:account_id`, `:mandate_type`
  (MIN_DUE/FULL/FIXED), `:fixed_amount` (FIXED only), `:funding_reference`.
  Replaces any existing active mandate.
  """
  @spec enroll(map()) :: {:ok, AutopayMandate.t()} | {:error, term()}
  def enroll(%{account_id: account_id} = attrs) do
    Repo.transaction(fn ->
      cancel_active(account_id)

      case Repo.insert(AutopayMandate.changeset(%AutopayMandate{}, attrs)) do
        {:ok, mandate} -> mandate
        {:error, cs} -> Repo.rollback(cs)
      end
    end)
  end

  @doc "Cancel the account's active mandate (no-op when none)."
  @spec cancel(Ecto.UUID.t()) :: :ok
  def cancel(account_id) do
    cancel_active(account_id)
    :ok
  end

  @doc "The account's active mandate, or nil."
  @spec active_mandate(Ecto.UUID.t()) :: AutopayMandate.t() | nil
  def active_mandate(account_id) do
    Repo.one(
      from m in AutopayMandate,
        where: m.account_id == ^account_id and m.active == true
    )
  end

  # ---------------------------------------------------------------------------
  # Execution (called by AutopayRunJob)
  # ---------------------------------------------------------------------------

  @doc """
  Collect every active mandate whose payment is due on `run_date`.

  Returns `%{collected: n, skipped_zero: n, failed: n, not_due: n}`.
  """
  @spec run_due_mandates(Date.t()) :: map()
  def run_due_mandates(run_date \\ Date.utc_today()) do
    mandates =
      Repo.all(
        from m in AutopayMandate,
          join: a in Account, on: a.account_id == m.account_id,
          where: m.active == true and a.account_status == "ACTIVE",
          select: {m, a}
      )

    Enum.reduce(mandates, %{collected: 0, skipped_zero: 0, failed: 0, not_due: 0},
      fn {mandate, account}, acc ->
        case collect_one(mandate, account, run_date) do
          :collected    -> Map.update!(acc, :collected, &(&1 + 1))
          :skipped_zero -> Map.update!(acc, :skipped_zero, &(&1 + 1))
          :not_due      -> Map.update!(acc, :not_due, &(&1 + 1))
          :failed       -> Map.update!(acc, :failed, &(&1 + 1))
        end
      end)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp collect_one(mandate, account, run_date) do
    bucket = statement_bucket(account.account_id)

    with %BalanceBucket{} <- bucket || :no_statement,
         due_date = payment_due_date(account, bucket),
         true <- Date.compare(due_date, run_date) == :eq || :not_due,
         amount = collection_amount(mandate, bucket),
         true <- D.compare(amount, 0) == :gt || :zero do
      reference = "autopay:#{account.account_id}:#{Date.to_iso8601(due_date)}"

      case PaymentIntake.receive_payment(%{
             account_id: account.account_id,
             amount: amount,
             channel: "direct_debit",
             reference: reference
           }) do
        {:ok, _} ->
          Logger.info("[Autopay] Collected #{amount} for #{account.account_id} " <>
                      "(#{mandate.mandate_type}, due #{due_date})")
          :collected

        {:error, :duplicate_payment} ->
          # Already collected this cycle (job re-run) — success by intent
          :collected

        {:error, reason} ->
          Logger.error("[Autopay] Collection failed for #{account.account_id}: " <>
                       "#{inspect(reason)}")
          :failed
      end
    else
      :no_statement -> :not_due
      :not_due      -> :not_due
      :zero         -> :skipped_zero
    end
  end

  # Latest bucket that has a statement on it
  defp statement_bucket(account_id) do
    Repo.one(
      from b in BalanceBucket,
        where: b.account_id == ^account_id and b.statement_balance > 0,
        order_by: [desc: b.balance_date],
        limit: 1
    )
  end

  defp payment_due_date(account, bucket) do
    due_days =
      case ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id,
                               account.block_id || "", :payment_due_days) do
        {:ok, days} when is_integer(days) and days > 0 -> days
        _ -> 21
      end

    Date.add(bucket.balance_date, due_days)
  end

  defp collection_amount(%AutopayMandate{mandate_type: "MIN_DUE"}, bucket),
    do: bucket.minimum_payment || D.new(0)

  defp collection_amount(%AutopayMandate{mandate_type: "FULL"}, bucket),
    do: bucket.statement_balance || D.new(0)

  defp collection_amount(%AutopayMandate{mandate_type: "FIXED", fixed_amount: fixed}, bucket) do
    # Never collect more than is owed
    D.min(fixed || D.new(0), bucket.statement_balance || D.new(0))
  end

  defp cancel_active(account_id) do
    Repo.update_all(
      from(m in AutopayMandate, where: m.account_id == ^account_id and m.active == true),
      set: [active: false,
            cancelled_at: DateTime.utc_now() |> DateTime.truncate(:second),
            updated_at: DateTime.utc_now()]
    )
  end
end
