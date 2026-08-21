defmodule VmuCore.WPS.Refunds do
  @moduledoc """
  Employer recovery of a salary credit, under maker-checker (W4).

  ```
  request(salary_credit_id, opts)  -> a PENDING request
  approve(request_id, checker, note) -> the money comes back
  reject(request_id, checker, note)  -> it does not
  ```

  ## Why two people

  This is the one WPS operation that moves money *against* the worker. An
  employer overpaid, or paid someone who had already left — both are real, and
  both are also what a fraudulent request would claim. The bank cannot verify
  the employer's account of it, so the control is procedural: one person
  requests, a different person decides, and the record names both.
  `CMS.FeeWaiver` and `CMS.FinancialAdjustment` take the same posture.

  ## Spent wages cannot be recovered

  The refund consumes the worker's prepaid balance. If they have already spent
  the money the request fails with `:insufficient_funds`, and that is a real
  answer rather than an error to route around — recovering it would mean driving
  a wage account negative, which is not something a wage account may do.

  A failure of that kind is recorded as `FAILED`, deliberately distinct from
  `REJECTED`: one is the world refusing, the other is a person deciding.

  ## The GL side

  Posts `REVERSAL` under `WPS_PREPAID` — money leaving the salary liability back
  to clearing — rather than `PURCHASE`, which is what a *worker's* spend would
  be. The two share an account pair, so only the event type tells a later reader
  that this was a recovery and not a purchase. That distinction is why
  `Posting.LegacyEvent` carries an explicit `:event_type` escape hatch.
  """

  import Ecto.Query, warn: false

  require Logger

  alias VmuCore.Repo
  alias VmuCore.CMS.{InternalGlPoster, PrepaidLedger}
  alias VmuCore.WPS.{RefundRequest, SalaryCredit}

  # ---------------------------------------------------------------------------
  # Maker
  # ---------------------------------------------------------------------------

  @doc """
  Raises a refund request against a posted salary credit.

  Options: `:amount` (defaults to the whole credit), `:reason` (required),
  `:requested_by` (required).
  """
  @spec request(Ecto.UUID.t(), keyword()) :: {:ok, RefundRequest.t()} | {:error, term()}
  def request(salary_credit_id, opts) do
    with {:ok, credit} <- fetch_refundable(salary_credit_id),
         {:ok, amount} <- validate_amount(credit, Keyword.get(opts, :amount)) do
      %RefundRequest{}
      |> RefundRequest.changeset(%{
        salary_credit_id: credit.salary_credit_id,
        employer_id: credit.employer_id,
        amount: amount,
        reason: Keyword.fetch!(opts, :reason),
        requested_by: Keyword.fetch!(opts, :requested_by),
        requested_at: DateTime.utc_now()
      })
      |> Repo.insert()
    end
  end

  defp fetch_refundable(salary_credit_id) do
    case Repo.get(SalaryCredit, salary_credit_id) do
      nil ->
        {:error, :salary_credit_not_found}

      %SalaryCredit{status: "POSTED"} = credit ->
        {:ok, credit}

      %SalaryCredit{status: status} ->
        # Nothing was paid, so there is nothing to recover. An unpaid line is
        # cancelled through the exception queue, not refunded.
        {:error, {:not_posted, status}}
    end
  end

  defp validate_amount(credit, nil), do: {:ok, credit.net_amount}

  defp validate_amount(credit, amount) do
    cond do
      Decimal.compare(amount, Decimal.new(0)) != :gt ->
        {:error, :invalid_amount}

      Decimal.compare(amount, credit.net_amount) == :gt ->
        {:error, {:exceeds_credit, credit.net_amount}}

      true ->
        {:ok, amount}
    end
  end

  # ---------------------------------------------------------------------------
  # Checker
  # ---------------------------------------------------------------------------

  @doc """
  Approves a request and recovers the money.

  `checker` must differ from the requester. Returns `{:error, :insufficient_funds}`
  when the worker has already spent the wages — the request is marked `FAILED`
  rather than approved, because approving something that did not happen would be
  a lie in the audit trail.
  """
  @spec approve(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, RefundRequest.t()} | {:error, term()}
  def approve(refund_request_id, checker, note \\ nil) do
    with {:ok, request} <- fetch_pending(refund_request_id),
         :ok <- validate_checker(request, checker) do
      credit = Repo.get!(SalaryCredit, request.salary_credit_id)

      case recover(request, credit, checker) do
        {:ok, _} ->
          decide(request, "APPROVED", checker, note)

        {:error, reason} ->
          Logger.warning(
            "[WPS] refund #{request.refund_request_id} could not recover " <>
              "#{request.amount}: #{inspect(reason)}"
          )

          mark_failed(request, checker, reason)
          {:error, reason}
      end
    end
  end

  @doc "Declines a request. `checker` must differ from the requester."
  @spec reject(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, RefundRequest.t()} | {:error, term()}
  def reject(refund_request_id, checker, note) do
    with {:ok, request} <- fetch_pending(refund_request_id),
         :ok <- validate_checker(request, checker) do
      decide(request, "REJECTED", checker, note)
    end
  end

  defp fetch_pending(refund_request_id) do
    case Repo.get(RefundRequest, refund_request_id) do
      nil -> {:error, :refund_request_not_found}
      %RefundRequest{status: "PENDING"} = request -> {:ok, request}
      %RefundRequest{status: status} -> {:error, {:already_decided, status}}
    end
  end

  defp validate_checker(%RefundRequest{requested_by: maker}, checker) do
    cond do
      is_nil(checker) or checker == "" ->
        {:error, :checker_required}

      checker == maker ->
        {:error, :maker_cannot_be_checker}

      true ->
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Money
  # ---------------------------------------------------------------------------

  # Two steps, deliberately in this order: take the balance first, and only post
  # the GL if that succeeded. Posting first would record a recovery that then
  # could not happen.
  defp recover(request, credit, _checker) do
    key = "wps-refund:#{request.refund_request_id}"

    Repo.transaction(fn ->
      with {:ok, spend} <-
             PrepaidLedger.spend(credit.prepaid_account_id, request.amount,
               posted_by: "wps-refund",
               idempotency_key: key
             ),
           {:ok, _posting} <- post_reversal(credit, request, key) do
        spend
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp post_reversal(credit, request, key) do
    InternalGlPoster.post(%{
      account_id: credit.prepaid_account_id,
      idempotency_key: key,
      transaction_code: "REVERSAL",
      # The explicit escape hatch from `Posting.LegacyEvent`. REVERSAL and
      # PURCHASE post the same account pair for WPS_PREPAID, so without naming
      # the event a later reader could not tell an employer recovery from a
      # worker's own spending.
      event_type: "REVERSAL",
      dr_amount: request.amount,
      cr_amount: request.amount,
      posting_date: Date.utc_today(),
      value_date: Date.utc_today(),
      narrative: "WPS employer refund: #{String.slice(request.reason, 0, 80)}",
      source_ref: credit.payment_reference,
      bindings: %{"reason" => request.reason}
    })
  end

  defp decide(request, status, checker, note) do
    request
    |> RefundRequest.changeset(%{
      status: status,
      decided_by: checker,
      decided_at: DateTime.utc_now(),
      decision_note: note
    })
    |> Repo.update()
  end

  defp mark_failed(request, checker, reason) do
    request
    |> RefundRequest.changeset(%{
      status: "FAILED",
      decided_by: checker,
      decided_at: DateTime.utc_now(),
      failure_reason: reason |> inspect() |> String.slice(0, 300)
    })
    |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "Refund requests for an employer, newest first."
  @spec list(Ecto.UUID.t(), keyword()) :: [RefundRequest.t()]
  def list(employer_id, opts \\ []) do
    RefundRequest
    |> where([r], r.employer_id == ^employer_id)
    |> then(fn q ->
      case Keyword.get(opts, :status) do
        nil -> q
        status -> where(q, [r], r.status == ^status)
      end
    end)
    |> order_by([r], desc: r.requested_at)
    |> preload(:salary_credit)
    |> Repo.all()
  end

  @doc "Requests awaiting a decision — the checker's queue."
  @spec pending(Ecto.UUID.t()) :: [RefundRequest.t()]
  def pending(employer_id), do: list(employer_id, status: "PENDING")

  @doc "Fetches one request."
  @spec get(Ecto.UUID.t()) :: RefundRequest.t() | nil
  def get(refund_request_id), do: Repo.get(RefundRequest, refund_request_id)
end
