defmodule VmuCore.WPS.Disbursement do
  @moduledoc """
  Pays a salary file (W3).

  ```
  pre_flight(wps_file_id)   -> what would happen, nothing moves
  post_batch(wps_file_id)   -> the money moves
  retry(exception_id)       -> one remediated line
  ```

  ## Pre-flight first, deliberately

  A salary batch is irreversible in the way that matters: once a worker has been
  paid, getting it back is an employer refund and a conversation, not a rollback.
  So resolution runs twice — once with nothing at stake, so an operator sees the
  seventeen unlinked workers *before* the other 383 are paid, and again at
  posting time because the roster may have been fixed in between.

  Nothing here requires the operator to approve; `post_batch/2` can be called
  directly. What the split buys is that it is *possible* to look first.

  ## Idempotency

  The posting key is derived from the employer's own `payment_reference`:

      wps:<employer_id>:<payment_reference>

  which is unique per employer at the database level. A re-run skips lines
  already `POSTED`, and even if that check were wrong the key means the ledger
  refuses the second posting. Two independent guards, because the failure they
  prevent is paying a worker twice.

  ## Money moves through `CMS.PrepaidLedger.load/1`

  Not by posting GL directly. `load/1` writes the prepaid ledger entry and the
  GL posting in one transaction, and it is the same entry point every other
  prepaid funding path uses — the discipline `COL` follows in routing payments
  through `CMS.PaymentIntake` rather than reimplementing them.
  """

  import Ecto.Query, warn: false

  require Logger

  alias VmuCore.Repo
  alias VmuCore.CMS.{PrepaidAccount, PrepaidLedger}
  alias VmuCore.WPS.{Employer, Roster, SalaryCredit, SalaryCreditException, WpsFile}

  @channel "WPS_SALARY"

  # ---------------------------------------------------------------------------
  # Pre-flight
  # ---------------------------------------------------------------------------

  @doc """
  Reports what `post_batch/2` would do, without moving anything.

  Returns totals plus the per-line blockers, grouped by cause — which is the
  shape an operator acts on, because the fix for every unlinked worker is the
  same fix.
  """
  @spec pre_flight(Ecto.UUID.t()) :: {:ok, map()} | {:error, term()}
  def pre_flight(wps_file_id) do
    with {:ok, file, employer} <- load_file(wps_file_id) do
      credits = pending_credits(wps_file_id)
      resolutions = resolve_all(employer, credits)

      {payable, blocked} =
        Enum.split_with(credits, fn c -> match?({:ok, _}, resolutions[c.employee_id]) end)

      already_posted =
        Repo.one(
          from c in SalaryCredit,
            where: c.wps_file_id == ^wps_file_id and c.status == "POSTED",
            select: count(c.salary_credit_id)
        )

      {:ok,
       %{
         file: file,
         employer_disbursable: Employer.disbursable?(employer),
         payable_count: length(payable),
         payable_total: sum_net(payable),
         blocked_count: length(blocked),
         blocked_total: sum_net(blocked),
         already_posted_count: already_posted,
         blockers: group_blockers(blocked, resolutions)
       }}
    end
  end

  defp group_blockers(blocked, resolutions) do
    blocked
    |> Enum.group_by(fn credit ->
      {:error, reason} = resolutions[credit.employee_id]
      SalaryCreditException.classify(reason)
    end)
    |> Map.new(fn {type, credits} ->
      {type,
       %{
         count: length(credits),
         total: sum_net(credits),
         employees: credits |> Enum.map(& &1.employee_id) |> Enum.sort()
       }}
    end)
  end

  # ---------------------------------------------------------------------------
  # Posting
  # ---------------------------------------------------------------------------

  @doc """
  Disburses every payable line in the file.

  Lines that cannot be paid get an exception rather than stopping the batch —
  one unlinked worker must not prevent the other 383 being paid, which is the
  whole reason a payroll run needs an exception queue at all.

  Options: `:posted_by`.
  """
  @spec post_batch(Ecto.UUID.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def post_batch(wps_file_id, opts \\ []) do
    with {:ok, file, employer} <- load_file(wps_file_id),
         :ok <- check_disbursable(employer) do
      mark_file(file, "POSTING")

      credits = pending_credits(wps_file_id)
      # Resolved again rather than trusting pre-flight: the roster may have been
      # fixed in between, and that is exactly the workflow being encouraged.
      resolutions = resolve_all(employer, credits)

      result =
        Enum.reduce(credits, %{posted: 0, failed: 0, amount: Decimal.new(0)}, fn credit, acc ->
          case disburse(credit, employer, resolutions[credit.employee_id], opts) do
            {:ok, _} ->
              %{acc | posted: acc.posted + 1, amount: Decimal.add(acc.amount, credit.net_amount)}

            {:error, _reason} ->
              %{acc | failed: acc.failed + 1}
          end
        end)

      mark_file(file, "COMPLETED")

      Logger.info(
        "[WPS] batch #{file.filename} employer=#{employer.employer_code} " <>
          "posted=#{result.posted} failed=#{result.failed} amount=#{result.amount}"
      )

      {:ok, result}
    end
  end

  @doc """
  Retries one exception.

  Re-resolves from scratch: the point of the queue is that an operator has
  linked the worker or reopened the account since it failed.
  """
  @spec retry(Ecto.UUID.t(), keyword()) :: {:ok, SalaryCredit.t()} | {:error, term()}
  def retry(exception_id, opts \\ []) do
    case Repo.get(SalaryCreditException, exception_id) do
      nil ->
        {:error, :exception_not_found}

      %SalaryCreditException{status: status} when status != "OPEN" ->
        {:error, {:not_open, status}}

      exception ->
        credit = Repo.get!(SalaryCredit, exception.salary_credit_id)
        employer = Roster.get_employer(exception.employer_id)

        resolution = Roster.resolve(employer.employer_id, credit.employee_id)
        disburse(credit, employer, resolution, opts)
    end
  end

  # ---------------------------------------------------------------------------
  # One line
  # ---------------------------------------------------------------------------

  defp disburse(%SalaryCredit{status: "POSTED"} = credit, _employer, _resolution, _opts) do
    # Already paid. The status check is the cheap guard; the idempotency key
    # below is the one that holds if this were ever wrong.
    {:ok, credit}
  end

  defp disburse(credit, employer, {:error, reason}, _opts) do
    record_failure(credit, employer, reason)
    {:error, reason}
  end

  defp disburse(credit, employer, {:ok, account_id}, opts) do
    key = idempotency_key(employer, credit)

    load_attrs = %{
      prepaid_account_id: account_id,
      amount: credit.net_amount,
      channel: @channel,
      posted_by: Keyword.get(opts, :posted_by, "wps"),
      external_reference: credit.payment_reference,
      idempotency_key: key
    }

    case PrepaidLedger.load(load_attrs) do
      {:ok, _} ->
        mark_posted(credit, account_id)

      {:error, :duplicate} ->
        # The ledger already holds this payment. The credit's status was stale,
        # not the money — so record the truth rather than raising an exception
        # for a worker who has in fact been paid.
        Logger.warning(
          "[WPS] #{credit.payment_reference} was already posted; " <>
            "reconciling status from the ledger"
        )

        mark_posted(credit, account_id)

      {:error, reason} ->
        record_failure(credit, employer, reason)
        {:error, reason}
    end
  end

  # The employer's own payment reference is the idempotency anchor: it is unique
  # per employer in the database, and it is the identifier the employer, the
  # bank and the regulator all use for the same payment.
  defp idempotency_key(employer, credit) do
    "wps:#{employer.employer_id}:#{credit.payment_reference}"
  end

  defp mark_posted(credit, account_id) do
    credit
    |> SalaryCredit.changeset(%{
      status: "POSTED",
      prepaid_account_id: account_id,
      posted_at: DateTime.utc_now(),
      failure_reason: nil
    })
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        resolve_open_exception(updated)
        {:ok, updated}

      error ->
        error
    end
  end

  defp record_failure(credit, employer, reason) do
    type = SalaryCreditException.classify(reason)
    described = SalaryCreditException.describe(reason)
    # The credit's own column is narrower than the exception's — the exception
    # is where the full detail belongs, the credit carries a summary.
    summary = String.slice(described, 0, 300)

    Repo.transaction(fn ->
      credit
      |> SalaryCredit.changeset(%{status: "FAILED", failure_reason: summary})
      |> Repo.update!()

      case open_exception(credit) do
        nil ->
          %SalaryCreditException{}
          |> SalaryCreditException.changeset(%{
            salary_credit_id: credit.salary_credit_id,
            employer_id: employer.employer_id,
            exception_type: type,
            reason: described,
            attempt_count: 1,
            last_attempted_at: DateTime.utc_now()
          })
          |> Repo.insert!()

        existing ->
          # Update in place rather than stacking a second row: the queue should
          # show outstanding work, and the attempt history lives in the counter.
          existing
          |> SalaryCreditException.changeset(%{
            exception_type: type,
            reason: described,
            attempt_count: existing.attempt_count + 1,
            last_attempted_at: DateTime.utc_now()
          })
          |> Repo.update!()
      end
    end)
  end

  defp resolve_open_exception(credit) do
    case open_exception(credit) do
      nil ->
        :ok

      exception ->
        exception
        |> SalaryCreditException.changeset(%{
          status: "RESOLVED",
          resolved_at: DateTime.utc_now(),
          resolution_note: "posted successfully"
        })
        |> Repo.update!()

        :ok
    end
  end

  defp open_exception(credit) do
    Repo.one(
      from e in SalaryCreditException,
        where: e.salary_credit_id == ^credit.salary_credit_id and e.status == "OPEN"
    )
  end

  # ---------------------------------------------------------------------------
  # Shared
  # ---------------------------------------------------------------------------

  defp load_file(wps_file_id) do
    case Repo.get(WpsFile, wps_file_id) do
      nil ->
        {:error, :file_not_found}

      %WpsFile{status: "REJECTED"} ->
        {:error, :file_rejected}

      file ->
        case Roster.get_employer(file.employer_id) do
          nil -> {:error, :employer_not_found}
          employer -> {:ok, file, employer}
        end
    end
  end

  defp check_disbursable(employer) do
    if Employer.disbursable?(employer),
      do: :ok,
      else: {:error, :employer_not_disbursable}
  end

  # Everything not already paid — so a re-run picks up the failures and skips
  # the successes.
  defp pending_credits(wps_file_id) do
    SalaryCredit
    |> where([c], c.wps_file_id == ^wps_file_id and c.status != "POSTED")
    |> order_by([c], asc: c.line_number)
    |> Repo.all()
  end

  # One query for the roster and one for the accounts, rather than two per line.
  # A payroll file is a batch; resolving it row by row is what makes an import
  # take minutes instead of seconds.
  defp resolve_all(employer, credits) do
    resolutions =
      credits
      |> Enum.map(& &1.employee_id)
      |> then(&Roster.resolve_many(employer.employer_id, &1))

    account_ids =
      resolutions
      |> Enum.flat_map(fn
        {_id, {:ok, account_id}} -> [account_id]
        _ -> []
      end)
      |> Enum.uniq()

    inactive = inactive_accounts(account_ids)

    Map.new(resolutions, fn
      {employee_id, {:ok, account_id}} ->
        if MapSet.member?(inactive, account_id) do
          {employee_id, {:error, :prepaid_account_not_active}}
        else
          {employee_id, {:ok, account_id}}
        end

      other ->
        other
    end)
  end

  # A closed or blocked account is a *pre-flight* answer, not something to
  # discover one failed posting at a time.
  defp inactive_accounts([]), do: MapSet.new()

  defp inactive_accounts(account_ids) do
    PrepaidAccount
    |> where([a], a.prepaid_account_id in ^account_ids)
    |> Repo.all()
    |> Enum.reject(&PrepaidAccount.active?/1)
    |> Enum.map(& &1.prepaid_account_id)
    |> MapSet.new()
  end

  defp sum_net(credits) do
    Enum.reduce(credits, Decimal.new(0), fn c, acc -> Decimal.add(acc, c.net_amount) end)
  end

  defp mark_file(file, status) do
    file |> WpsFile.changeset(%{status: status}) |> Repo.update()
  end

  # ---------------------------------------------------------------------------
  # Reads
  # ---------------------------------------------------------------------------

  @doc "Open exceptions for an employer, newest first."
  @spec open_exceptions(Ecto.UUID.t(), keyword()) :: [SalaryCreditException.t()]
  def open_exceptions(employer_id, opts \\ []) do
    SalaryCreditException
    |> where([e], e.employer_id == ^employer_id and e.status == "OPEN")
    |> then(fn q ->
      case Keyword.get(opts, :exception_type) do
        nil -> q
        type -> where(q, [e], e.exception_type == ^type)
      end
    end)
    |> order_by([e], desc: e.inserted_at)
    |> preload(:salary_credit)
    |> Repo.all()
  end

  @doc """
  Open exceptions grouped by cause, with counts and amounts.

  The operator's queue view: what is outstanding, and how much money it
  represents.
  """
  @spec exception_summary(Ecto.UUID.t()) :: %{String.t() => map()}
  def exception_summary(employer_id) do
    SalaryCreditException
    |> join(:inner, [e], c in SalaryCredit, on: c.salary_credit_id == e.salary_credit_id)
    |> where([e, _c], e.employer_id == ^employer_id and e.status == "OPEN")
    |> group_by([e, _c], e.exception_type)
    |> select([e, c], {e.exception_type, count(e.exception_id), sum(c.net_amount)})
    |> Repo.all()
    |> Map.new(fn {type, count, total} ->
      {type, %{count: count, total: total || Decimal.new(0)}}
    end)
  end

  @doc """
  Closes an exception without paying it — the worker left, the line was a
  duplicate, the employer withdrew it.

  Kept separate from `retry/2` because abandoning a regulated payment
  instruction is a decision someone owns, and the note records who and why.
  """
  @spec abandon(Ecto.UUID.t(), String.t(), String.t()) ::
          {:ok, SalaryCreditException.t()} | {:error, term()}
  def abandon(exception_id, note, resolved_by) do
    case Repo.get(SalaryCreditException, exception_id) do
      nil ->
        {:error, :exception_not_found}

      %SalaryCreditException{status: status} when status != "OPEN" ->
        {:error, {:not_open, status}}

      exception ->
        exception
        |> SalaryCreditException.changeset(%{
          status: "ABANDONED",
          resolved_at: DateTime.utc_now(),
          resolved_by: resolved_by,
          resolution_note: note
        })
        |> Repo.update()
    end
  end
end
