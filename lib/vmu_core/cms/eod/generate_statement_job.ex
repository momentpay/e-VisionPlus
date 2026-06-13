defmodule VmuCore.CMS.EOD.GenerateStatementJob do
  @moduledoc """
  EOD Step 4 — Generate the monthly billing statement for one account.

  Delegates to StatementGenerator.generate/3 which snapshots the statement
  balance, minimum payment, and next_statement_date into the DB.
  Enqueues FlushGlJob on success.
  """

  use Oban.Worker, queue: :eod, max_attempts: 3, unique: [period: 86_400]

  require Logger
  alias VmuCore.CMS.StatementGenerator
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.Repo
  alias VmuCore.CMS.Account

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)
    account  = Repo.get!(Account, account_id)

    {:ok, apr} =
      ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id, account.block_id, :apr_percentage)

    case StatementGenerator.generate(account_id, eod_date, apr_percentage: apr) do
      {:ok, stmt} ->
        Logger.info("[EOD] Statement: account=#{account_id} balance=#{stmt.statement_balance}")

        %{account_id: account_id, eod_date: eod_date_str}
        |> VmuCore.CMS.EOD.FlushGlJob.new()
        |> Oban.insert()

        :ok

      {:error, reason} ->
        Logger.error("[EOD] Statement failed: account=#{account_id} reason=#{inspect(reason)}")
        {:error, reason}
    end
  end
end
