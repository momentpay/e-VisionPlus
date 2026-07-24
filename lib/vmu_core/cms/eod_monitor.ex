defmodule VmuCore.CMS.EodMonitor do
  @moduledoc """
  EOD job status visibility + rerun controls (CMS FR-057 — flagged in
  `CMS_Feature_Status.md` as "the most operationally significant" of CMS's
  nine open gaps: no admin screen shows EOD job status or exposes a rerun
  action).

  The EOD pipeline (`docs/...`/`lib/vmu_core/cms/eod/*.ex`) is a real Oban
  chain, not a single job: `EodSchedulerJob` enqueues one `LockAccountsJob`
  per due `cycle_code`, which fans out to one `AccrueInterestJob` per
  account, which chains `AgeBucketsJob` → `GenerateStatementJob` →
  `FlushGlJob`. There is no explicit "batch/run" entity in the data model —
  `eod_date` (present on every job in the chain) is the natural grouping
  key this module uses instead of inventing a new table.

  Reads `Oban.Job` directly (Oban's own public Ecto schema — correctly
  typed for the `oban_job_state` Postgres enum, unlike a raw schemaless
  query against `"oban_jobs"`) rather than adding a parallel EOD-specific
  audit table.
  """

  import Ecto.Query
  alias VmuCore.Repo

  @eod_workers ~w[
    VmuCore.CMS.EOD.LockAccountsJob
    VmuCore.CMS.EOD.AccrueInterestJob
    VmuCore.CMS.EOD.AgeBucketsJob
    VmuCore.CMS.EOD.GenerateStatementJob
    VmuCore.CMS.EOD.FlushGlJob
    VmuCore.CMS.EOD.ReinstateLimitJob
  ]

  @doc "Short worker name (drops the VmuCore.CMS.EOD. prefix) for display."
  def short_worker(worker), do: worker |> String.split(".") |> List.last()

  @doc "All EOD stage worker names, in pipeline order, for consistent column ordering."
  def eod_workers, do: @eod_workers

  @doc """
  Distinct EOD run dates (most recent first) that have at least one job in
  the `eod` queue, each with a `%{worker => %{state => count}}` summary —
  the "how far did today's EOD get" view.
  """
  @spec list_runs(pos_integer()) :: [%{eod_date: String.t(), workers: map()}]
  def list_runs(limit \\ 14) do
    dates =
      Repo.all(
        from j in Oban.Job,
          where: j.queue == "eod",
          select: fragment("?->>'eod_date'", j.args),
          distinct: true
      )
      |> Enum.reject(&is_nil/1)
      |> Enum.sort(:desc)
      |> Enum.take(limit)

    Enum.map(dates, fn date -> %{eod_date: date, workers: worker_summary(date)} end)
  end

  defp worker_summary(eod_date) do
    Repo.all(
      from j in Oban.Job,
        where: j.queue == "eod" and fragment("?->>'eod_date'", j.args) == ^eod_date,
        group_by: [j.worker, j.state],
        select: {j.worker, j.state, count(j.id)}
    )
    |> Enum.reduce(%{}, fn {worker, state, count}, acc ->
      Map.update(acc, worker, %{state => count}, &Map.put(&1, to_string(state), count))
    end)
  end

  # Real EOD data checked live, 2026-07-24: this dev DB has 2 real
  # `GenerateStatementJob` rows that have sat in `executing` since
  # 2026-07-10 (2 weeks) — Oban has no automatic "stuck executing" recovery
  # unless `Oban.Plugins.Lifeline` is configured (it isn't here). Ops has no
  # way to see this today. Treated as needing attention alongside
  # retryable/discarded, not just those two states.
  @stuck_executing_after_minutes 30

  @doc """
  Jobs needing operator attention in the `eod` queue, optionally scoped to
  one `eod_date`: `retryable`/`discarded` (real failures), plus `executing`
  jobs that have been running longer than #{@stuck_executing_after_minutes}
  minutes (very likely orphaned — Oban has no automatic recovery for these
  unless `Oban.Plugins.Lifeline` is configured, which this project doesn't
  do). Newest first.
  """
  @spec list_failed_jobs(String.t() | nil) :: [Oban.Job.t()]
  def list_failed_jobs(eod_date \\ nil) do
    stuck_cutoff = DateTime.utc_now() |> DateTime.add(-@stuck_executing_after_minutes * 60, :second)

    query =
      from j in Oban.Job,
        where:
          j.state in ["retryable", "discarded"] or
            (j.state == "executing" and j.attempted_at < ^stuck_cutoff),
        where: j.queue == "eod",
        order_by: [desc: j.id]

    query =
      if eod_date,
        do: where(query, [j], fragment("?->>'eod_date'", j.args) == ^eod_date),
        else: query

    Repo.all(query)
  end

  @doc """
  Retry a `retryable`/`discarded` job — resets it to `available` with
  `scheduled_at` now, via Oban's own `retry_job/1` (real Oban API, not a
  hand-rolled state transition).
  """
  @spec retry_job(pos_integer()) :: :ok | {:error, :not_found}
  def retry_job(job_id) do
    case Repo.get(Oban.Job, job_id) do
      nil -> {:error, :not_found}
      _job -> Oban.retry_job(job_id)
    end
  end
end
