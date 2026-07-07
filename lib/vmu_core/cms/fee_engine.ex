defmodule VmuCore.CMS.FeeEngine do
  @moduledoc """
  VisionPlus CMS Fee Engine.

  Assesses fees as specified by the control record hierarchy and posts them as
  double-entry GL entries via `InternalGlPoster.post_fee/5`. All amounts use
  Decimal arithmetic — no Float.

  ## Fee Types

  | Function              | Trigger                                      |
  |-----------------------|----------------------------------------------|
  | `assess_late_fee/3`   | Minimum payment not received before due date |
  | `assess_overlimit_fee/3` | Outstanding balance exceeds credit limit  |
  | `assess_annual_fee/3` | Account open-date anniversary (once per year)|
  | `assess_returned_payment_fee/3` | Payment returned / bounced        |

  ## Parameter Resolution

  Fee amounts are resolved from ParameterEngine using the standard cascade:
  Block → Logo → Bank → System. If a logo-level late_fee is configured and
  the block has no override, the logo value is used.

  ## Idempotency

  Each assessment generates a unique idempotency key (fee_type + account_id +
  posting_date). Oban job retries will not double-post fees.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.BalanceBucket, CMS.InternalGlPoster}
  alias VmuCore.Shared.ParameterEngine

  @doc """
  Assess a late payment fee when the minimum payment was not received.

  Called from `AgeBucketsJob` after determining the minimum was missed.
  Posts GL entry and increments `unpaid_fees` on the balance bucket.

  Returns `:ok | {:skipped, reason} | {:error, reason}`.
  """
  @spec assess_late_fee(String.t(), map(), Date.t()) ::
          :ok | {:skipped, atom()} | {:error, term()}
  def assess_late_fee(account_id, account, posting_date) do
    with {:ok, fee_amount} <- resolve_fee(account, :late_fee),
         :ok <- guard_positive(fee_amount, :late_fee_is_zero) do
      idem_key = "LATE_FEE:#{account_id}:#{posting_date}"

      case InternalGlPoster.post_fee(account_id, fee_amount, "LATE_FEE", posting_date, idem_key) do
        {:ok, _entry} ->
          increment_unpaid_fees(account_id, fee_amount, posting_date)
          Logger.info("[FeeEngine] Late fee #{fee_amount} posted for account #{account_id}")
          :ok

        {:error, :duplicate} ->
          Logger.debug("[FeeEngine] Late fee already posted for #{account_id} on #{posting_date}")
          {:skipped, :already_posted}

        {:error, reason} ->
          Logger.error("[FeeEngine] Late fee GL post failed for #{account_id}: #{inspect(reason)}")
          {:error, reason}
      end
    end
  end

  @doc """
  Assess an overlimit fee when the account balance exceeds the credit limit.

  The overlimit fee is only applied if:
  - `overlimit_fee` is configured and > 0 in the parameter cascade, AND
  - The account balance actually exceeds `credit_limit`

  Returns `:ok | {:skipped, reason} | {:error, reason}`.
  """
  @spec assess_overlimit_fee(String.t(), map(), Date.t()) ::
          :ok | {:skipped, atom()} | {:error, term()}
  def assess_overlimit_fee(account_id, account, posting_date) do
    with {:ok, fee_amount} <- resolve_fee(account, :overlimit_fee),
         :ok <- guard_positive(fee_amount, :overlimit_fee_is_zero),
         :ok <- check_overlimit(account) do
      idem_key = "OVERLIMIT_FEE:#{account_id}:#{posting_date}"

      case InternalGlPoster.post_fee(account_id, fee_amount, "OVERLIMIT_FEE", posting_date, idem_key) do
        {:ok, _entry} ->
          increment_unpaid_fees(account_id, fee_amount, posting_date)
          Logger.info("[FeeEngine] Overlimit fee #{fee_amount} posted for account #{account_id}")
          :ok

        {:error, :duplicate} ->
          {:skipped, :already_posted}

        {:error, reason} ->
          Logger.error("[FeeEngine] Overlimit fee GL post failed for #{account_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:skipped, reason} -> {:skipped, reason}
    end
  end

  @doc """
  Assess an annual membership fee on the account's open-date anniversary.

  Should be called from `FlushGlJob` during EOD processing. The function
  checks whether today is the anniversary date before posting.

  Returns `:ok | {:skipped, reason} | {:error, reason}`.
  """
  @spec assess_annual_fee(String.t(), map(), Date.t()) ::
          :ok | {:skipped, atom()} | {:error, term()}
  def assess_annual_fee(account_id, account, posting_date) do
    with {:ok, fee_amount} <- resolve_fee(account, :annual_fee),
         :ok <- guard_positive(fee_amount, :annual_fee_is_zero),
         :ok <- check_anniversary(account, posting_date) do
      idem_key = "ANNUAL_FEE:#{account_id}:#{posting_date}"

      case InternalGlPoster.post_fee(account_id, fee_amount, "ANNUAL_FEE", posting_date, idem_key) do
        {:ok, _entry} ->
          increment_unpaid_fees(account_id, fee_amount, posting_date)
          Logger.info("[FeeEngine] Annual fee #{fee_amount} posted for account #{account_id} (anniversary)")
          :ok

        {:error, :duplicate} ->
          {:skipped, :already_posted}

        {:error, reason} ->
          Logger.error("[FeeEngine] Annual fee GL post failed for #{account_id}: #{inspect(reason)}")
          {:error, reason}
      end
    else
      {:skipped, reason} -> {:skipped, reason}
    end
  end

  @doc """
  Assess a returned payment fee (e.g. bounced cheque, NSF bank transfer).

  Called from the payment processing path when a payment reversal is received.
  """
  @spec assess_returned_payment_fee(String.t(), map(), Date.t()) ::
          :ok | {:skipped, atom()} | {:error, term()}
  def assess_returned_payment_fee(account_id, account, posting_date) do
    with {:ok, fee_amount} <- resolve_fee(account, :returned_payment_fee),
         :ok <- guard_positive(fee_amount, :returned_payment_fee_is_zero) do
      idem_key = "RETURNED_PMT_FEE:#{account_id}:#{posting_date}"

      case InternalGlPoster.post_fee(account_id, fee_amount, "RETURNED_PMT_FEE", posting_date, idem_key) do
        {:ok, _entry} ->
          increment_unpaid_fees(account_id, fee_amount, posting_date)
          Logger.info("[FeeEngine] Returned payment fee #{fee_amount} posted for #{account_id}")
          :ok

        {:error, :duplicate} ->
          {:skipped, :already_posted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Post a card replacement fee when a card is reissued (lost, stolen, or damaged).

  The fee amount is read from the `:card_replacement_fee` parameter in the
  4-level cascade (Block → Logo → Bank → Sys). If not configured or zero, the
  call is a no-op.

  `event_ref` should be the non_monetary_event.event_id of the card_reissue
  event, used as part of the idempotency key so a retry of the reissue event
  doesn't double-post the fee.

  Returns `:ok`, `{:skipped, reason}`, or `{:error, reason}`.
  """
  def assess_card_replacement_fee(account_id, account, event_ref, posting_date \\ Date.utc_today()) do
    with {:ok, fee_amount} <- resolve_fee(account, :card_replacement_fee),
         :ok <- guard_positive(fee_amount, :card_replacement_fee_is_zero) do
      idem_key = "CARD_REPLACE_FEE:#{account_id}:#{event_ref}"

      case InternalGlPoster.post_fee(account_id, fee_amount, "CARD_REPLACE_FEE", posting_date, idem_key) do
        {:ok, _entry} ->
          increment_unpaid_fees(account_id, fee_amount, posting_date)
          Logger.info("[FeeEngine] Card replacement fee #{fee_amount} posted for #{account_id} (event=#{event_ref})")
          :ok

        {:error, :duplicate} ->
          {:skipped, :already_posted}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # ── Private Helpers ──────────────────────────────────────────────────────────

  # Resolve a fee parameter via the 4-level cascade.
  # account must have :sys_id, :bank_id, :logo_id, :block_id
  defp resolve_fee(%{sys_id: sys, bank_id: bank, logo_id: logo, block_id: block}, fee_key) do
    case ParameterEngine.get(sys, bank, logo, block, fee_key) do
      {:ok, amount} when not is_nil(amount) ->
        {:ok, Decimal.new(amount)}

      _ ->
        Logger.debug("[FeeEngine] #{fee_key} not configured for logo=#{logo}")
        {:skipped, :not_configured}
    end
  end

  defp guard_positive(amount, skip_reason) do
    if Decimal.compare(amount, Decimal.new(0)) == :gt,
      do: :ok,
      else: {:skipped, skip_reason}
  end

  # Annual fee: only post if today is (open_date month/day) in any year after opening
  defp check_anniversary(%{open_date: nil}, _posting_date), do: {:skipped, :no_open_date}
  defp check_anniversary(%{open_date: open_date}, posting_date) do
    if open_date.month == posting_date.month and
       open_date.day   == posting_date.day and
       posting_date.year > open_date.year do
      :ok
    else
      {:skipped, :not_anniversary}
    end
  end

  # Overlimit: check if outstanding balance > credit_limit
  defp check_overlimit(%{open_to_buy: otb}) when not is_nil(otb) do
    if Decimal.compare(otb, Decimal.new(0)) == :lt,
      do: :ok,
      else: {:skipped, :not_overlimit}
  end
  defp check_overlimit(_), do: {:skipped, :no_otb_data}

  # Increment unpaid_fees on the most recent balance bucket for this account
  defp increment_unpaid_fees(account_id, fee_amount, posting_date) do
    result =
      Repo.one(
        from b in BalanceBucket,
          where: b.account_id == ^account_id,
          order_by: [desc: b.balance_date],
          limit: 1
      )

    case result do
      nil ->
        # No bucket yet — create a stub bucket for the fee
        %BalanceBucket{}
        |> BalanceBucket.changeset(%{
          account_id:   account_id,
          balance_date: posting_date,
          unpaid_fees:  fee_amount
        })
        |> Repo.insert(on_conflict: :nothing)

      bucket ->
        new_fees = Decimal.add(bucket.unpaid_fees || Decimal.new(0), fee_amount)

        Repo.update_all(
          from(b in BalanceBucket,
            where: b.account_id == ^account_id and b.balance_date == ^bucket.balance_date),
          set: [unpaid_fees: new_fees, updated_at: NaiveDateTime.utc_now()]
        )
    end

    :ok
  end
end
