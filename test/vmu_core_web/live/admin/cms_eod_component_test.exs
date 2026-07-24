defmodule VmuCoreWeb.Live.Admin.CmsEodComponentTest do
  @moduledoc """
  Live tests for CMS FR-057 (EOD job status + rerun controls). Real
  Postgres via Sandbox, real `Oban.Job` rows inserted directly (not via
  `Oban.insert/1`, which would execute them immediately under this
  project's `Oban testing: :inline` config) — this suite is testing the
  *status/rerun screen*, not the EOD jobs themselves.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    Authz.seed_default_matrix()
    Authz.refresh()
    :ok
  end

  defp operator_fixture(role) do
    %Operator{}
    |> Operator.changeset(%{
      username: "eod_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "EOD Test #{role}",
      pw_hash: "x",
      pw_salt: "x",
      role: role,
      status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{
      "operator_id" => operator.operator_id,
      "logged_in_at" => System.os_time(:second)
    })
  end

  defp job_fixture(attrs) do
    # Oban.Job's own timestamp fields are :utc_datetime_usec (DateTime with
    # microseconds) — the opposite precision requirement from the
    # :naive_datetime fields elsewhere in this codebase (see CDM-P2's
    # NaiveDateTime.truncate/2 fix) — don't truncate here.
    now = DateTime.utc_now()

    base = %{
      state: "available",
      queue: "eod",
      worker: "VmuCore.CMS.EOD.AccrueInterestJob",
      args: %{},
      max_attempts: 3,
      attempt: 1,
      priority: 0,
      errors: [],
      inserted_at: now,
      scheduled_at: now
    }

    struct(Oban.Job, Map.merge(base, attrs)) |> Repo.insert!()
  end

  describe "runs overview + needs-attention (SUPERVISOR)" do
    test "shows per-worker state counts and a retryable job with a working retry action" do
      eod_date = "2026-07-24-#{System.unique_integer([:positive])}"

      job =
        job_fixture(%{
          state: "retryable",
          worker: "VmuCore.CMS.EOD.AccrueInterestJob",
          args: %{"account_id" => "acct-123", "eod_date" => eod_date},
          errors: [%{"error" => "connection refused talking to ParameterEngine"}]
        })

      job_fixture(%{
        state: "completed",
        worker: "VmuCore.CMS.EOD.LockAccountsJob",
        args: %{"cycle_code" => "15", "eod_date" => eod_date}
      })

      operator = operator_fixture("SUPERVISOR")
      {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/cms_eod")

      assert html =~ eod_date
      assert html =~ "retryable"
      assert html =~ "connection refused"

      refute is_nil(job.id)

      html = view |> element("button", "Retry") |> render_click()
      assert html =~ "queued for retry"

      # `EodMonitor.retry_job/1`'s real behavior against a real connection
      # (not through the LiveView/Sandbox test harness) is verified
      # separately — a direct script confirmed `Oban.retry_job/1` flips
      # "retryable" -> "available" and refreshes `scheduled_at` with no
      # re-execution, no `:inline` involvement (that function doesn't go
      # through `Oban.insert/1`'s dispatch path at all). What this test
      # verifies is the LiveView side: the button exists only for
      # retryable/discarded rows, clicking it calls through without
      # crashing, and the success notice renders.
    end

    test "flags a long-stuck executing job without offering a retry button for it" do
      stuck_at = DateTime.utc_now() |> DateTime.add(-3600, :second)

      job_fixture(%{
        state: "executing",
        worker: "VmuCore.CMS.EOD.GenerateStatementJob",
        args: %{"account_id" => "acct-stuck"},
        attempted_at: stuck_at
      })

      operator = operator_fixture("SUPERVISOR")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/cms_eod")

      html = render(view)
      assert html =~ "GenerateStatementJob"
      assert html =~ "stuck — verify before acting"
      refute has_element?(view, "button", "Retry")
    end
  end

  describe "role gating (COMPLIANCE — view only)" do
    test "sees the data but cannot retry" do
      eod_date = "2026-07-24-#{System.unique_integer([:positive])}"

      job_fixture(%{
        state: "discarded",
        worker: "VmuCore.CMS.EOD.FlushGlJob",
        args: %{"account_id" => "acct-999", "eod_date" => eod_date}
      })

      operator = operator_fixture("COMPLIANCE")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/cms_eod")

      html = render(view)
      assert html =~ eod_date
      refute has_element?(view, "button", "Retry")
    end
  end
end
