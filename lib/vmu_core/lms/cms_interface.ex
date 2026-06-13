defmodule VmuCore.LMS.CmsInterface do
  @moduledoc """
  Interface from CMS (AR System) to LMS.

  In VisionPlus mainframe this is a sequential file written after CMS1 batch;
  in vMu it is a direct Oban job enqueue after EOD GL flush.

  Integration points:
    - `trigger_points_calculation/1` — called from CMS.EOD.FlushGLJob
    - `auto_enroll/2`               — called from CDM.ApplicationScorer on account approval
  """

  alias VmuCore.LMS.{Enrollment, Scheme}
  alias VmuCore.LMS.Oban.PointsCalculationJob
  alias VmuCore.Repo
  import Ecto.Query

  @doc "Enqueue a PointsCalculationJob for the given batch date (called by FlushGLJob)."
  def trigger_points_calculation(batch_date) do
    %{batch_date: Date.to_iso8601(batch_date)}
    |> PointsCalculationJob.new()
    |> Oban.insert()
  end

  @doc """
  Auto-enroll an AR account in all active schemes configured for the given org_id.
  Called from CDM.ApplicationScorer when a new account is approved.
  """
  def auto_enroll(ar_account_id, org_id) do
    schemes =
      from(s in Scheme, where: s.org_id == ^org_id and s.status == "ACTIVE")
      |> Repo.all()

    Enum.each(schemes, fn scheme ->
      Enrollment.enroll(ar_account_id, scheme.id, method: "AUTO")
    end)
  end
end
