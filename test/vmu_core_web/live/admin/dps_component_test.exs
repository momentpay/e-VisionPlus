defmodule VmuCoreWeb.Live.Admin.DpsComponentTest do
  @moduledoc """
  Live tests for the DPS ops UI (DPS-P5) — the first browser-driven coverage
  for anything DPS-P1..P4 built. No mocking: real Postgres via the Sandbox,
  real LiveComponent event handling, a real file upload + a real HTTP
  download round-trip through the plain controller route.

  `dps_disputes.account_id` has a real FK to `cms_accounts` (`:uuid`,
  `references: :cms_accounts`) — the pre-existing `VmuCore.DPS.
  DisputeLifecycleTest`'s plain fake-string account id convention was found
  live, while building this suite, to actually crash every one of its own
  tests with `Ecto.Query.CastError` (fixed in `dispute.ex`'s
  `put_provisional_credit_deadline/1`/`maybe_file_with_network/3` to degrade
  gracefully instead of raising — but a well-formed, non-existent UUID would
  still fail the real FK constraint on insert). This suite uses a genuine
  `CMS.Account` + `Shared.Customer` fixture instead.
  """

  use ExUnit.Case, async: false

  import Plug.Conn
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.DPS.{Dispute, ReasonCode}
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # Idempotent (on_conflict: nothing) — backfills the new "dps" grants
    # without disturbing rows other test runs may have already seeded.
    Authz.seed_default_matrix()
    Authz.refresh()

    :ok
  end

  defp operator_fixture(role) do
    %Operator{}
    |> Operator.changeset(%{
      username: "dps_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "DPS Test #{role}",
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

  # The test DB (`vmu_core_test`) carries no seeded SYS/BANK/LOGO/BLOCK rows —
  # found live, 2026-07-23, building this suite (`priv/repo/seeds.exs`
  # populates the dev DB only). Self-contained rather than depending on an
  # external seed step: builds its own minimal hierarchy inside the same
  # sandboxed transaction, using unique ids so it never collides across
  # concurrent test runs.
  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{(100 + rem(n, 900))}"
    bank_id = "B#{(100 + rem(n, 900))}"
    logo_id = "L#{(100 + rem(n, 900))}"
    block_id = "K#{(100 + rem(n, 900))}"

    %SysParameter{}
    |> SysParameter.changeset(%{sys_id: sys_id, description: "DPS test sys"})
    |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "DPS test bank"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id,
      bank_id: bank_id,
      logo_id: logo_id,
      bin_prefix: "424242",
      description: "DPS test logo"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id,
        bank_id: bank_id,
        first_name: "Dps",
        last_name: "Testholder",
        id_type: "PASSPORT",
        id_number: "DPS-TEST-#{System.unique_integer([:positive])}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id,
      sys_id: sys_id,
      bank_id: bank_id,
      logo_id: logo_id,
      block_id: block_id,
      pan_token: "dps-test-pan-#{System.unique_integer([:positive])}",
      last_four: "4242",
      expiry_date: "1230",
      credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  defp dispute_fixture(overrides \\ %{}) do
    account = account_fixture()

    attrs =
      Map.merge(
        %{
          account_id: account.account_id,
          transaction_date: Date.add(Date.utc_today(), -10),
          dispute_amount: D.new("250.00"),
          reason_code: "4853",
          network: "MC"
        },
        overrides
      )

    {:ok, dispute} = Dispute.file(attrs)
    dispute
  end

  describe "authentication gate" do
    test "unauthenticated request redirects to login" do
      assert {:error, {:redirect, %{to: "/visionplus/admin/login"}}} =
               live(build_conn(), "/visionplus/admin/dps")
    end
  end

  describe "case list + filing (SUPERVISOR — full access)" do
    test "files a new dispute and sees it in the open list" do
      account = account_fixture()
      operator = operator_fixture("SUPERVISOR")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/dps")

      assert has_element?(view, "button", "+ File Dispute")

      view |> element("button", "+ File Dispute") |> render_click()

      html =
        view
        |> form("form[phx-submit=file_dispute_submit]", %{
          "dispute" => %{
            "account_id" => account.account_id,
            "transaction_date" => Date.to_iso8601(Date.add(Date.utc_today(), -5)),
            "dispute_amount" => "199.99",
            "currency" => "MC",
            "network" => "MC",
            "reason_code" => "10.4"
          }
        })
        |> render_submit()

      # file_dispute_submit navigates straight into the new case's detail view
      assert html =~ "Dispute filed."
      assert html =~ "10.4"
      assert html =~ "199.99"

      assert Repo.get_by(Dispute, account_id: account.account_id, reason_code: "10.4")
    end

    test "deadline monitor renders an overdue badge for a past-due date" do
      # Filed with the default (near) transaction_date so its own
      # `DeadlineJob` correctly stays a no-op under `Oban testing: :inline`
      # (see dispute.ex/deadline_job.ex — a job must never act on a deadline
      # that hasn't actually arrived). The overdue date under test here is
      # backdated directly on the row afterward, bypassing the state
      # machine entirely — this test is only about the UI's badge
      # rendering for a given `chargeback_deadline` value, not about
      # exercising deadline-driven auto-transitions.
      dispute = dispute_fixture()

      Repo.update_all(
        from(d in Dispute, where: d.dispute_id == ^dispute.dispute_id),
        set: [chargeback_deadline: Date.add(Date.utc_today(), -5)]
      )

      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/dps")

      html =
        view
        |> with_target("#dps-component")
        |> render_click("open_case", %{"id" => to_string(dispute.dispute_id)})

      assert html =~ "Deadline Monitor"
      assert html =~ "badge-red"
      assert html =~ "overdue"
    end

    test "assign, note, and status transition all persist" do
      dispute = dispute_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/dps")
      view |> with_target("#dps-component") |> render_click("open_case", %{"id" => to_string(dispute.dispute_id)})

      html = view |> element("button", "Assign to me") |> render_click()
      assert html =~ operator.username

      html =
        view
        |> form("form[phx-submit=add_note]", %{"note" => "Called cardholder, confirmed non-participation."})
        |> render_submit()

      assert html =~ "Called cardholder"

      html =
        view
        |> form("form[phx-submit=transition]", %{"status" => "RETRIEVAL_REQUESTED"})
        |> render_submit()

      assert html =~ "Status updated to RETRIEVAL_REQUESTED"

      reloaded = Repo.get!(Dispute, dispute.dispute_id)
      assert reloaded.status == "RETRIEVAL_REQUESTED"
      assert reloaded.assigned_to == operator.username
    end

    test "evidence: real upload, list, download, and delete round-trip" do
      dispute = dispute_fixture()
      operator = operator_fixture("SUPERVISOR")
      conn = authed_conn(operator)

      {:ok, view, _html} = live(conn, "/visionplus/admin/dps")
      view |> with_target("#dps-component") |> render_click("open_case", %{"id" => to_string(dispute.dispute_id)})

      path = Path.join(System.tmp_dir!(), "dps_test_evidence_#{System.unique_integer([:positive])}.txt")
      File.write!(path, "cardholder statement evidence")

      view
      |> file_input("form[phx-submit=save_evidence]", :evidence, [
        %{name: "statement.txt", content: File.read!(path), type: "text/plain"}
      ])
      |> render_upload("statement.txt")

      view |> element("form[phx-submit=save_evidence]") |> render_submit()
      html = render(view)

      assert html =~ "statement.txt"
      assert html =~ "Evidence uploaded."

      evidence = Repo.get_by!(VmuCore.DPS.DisputeEvidence, dispute_id: dispute.dispute_id)
      assert evidence.filename == "statement.txt"
      assert evidence.backend == "db"

      download_conn =
        conn
        |> get("/visionplus/admin/dps/evidence/#{evidence.evidence_id}/download")

      assert response(download_conn, 200) == "cardholder statement evidence"
      assert get_resp_header(download_conn, "content-disposition") |> hd() =~ "statement.txt"

      html = view |> element("button", "Delete") |> render_click()
      assert html =~ "Evidence deleted."
      refute Repo.get(VmuCore.DPS.DisputeEvidence, evidence.evidence_id)

      File.rm(path)
    end
  end

  describe "reason codes" do
    test "SUPERVISOR can create a new reason code" do
      operator = operator_fixture("SUPERVISOR")
      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/dps")

      view |> element("button", "Reason Codes") |> render_click()
      view |> element("button", "+ New Reason Code") |> render_click()

      code_suffix = System.unique_integer([:positive])

      html =
        view
        |> form("form[phx-submit=reason_code_save]", %{
          "reason_code" => %{
            "network" => "VI",
            "reason_code" => "TEST-#{code_suffix}",
            "description" => "Test reason code",
            "category" => "fraud",
            "dispute_window_days" => "90",
            "evidence_required" => "signature, receipt"
          }
        })
        |> render_submit()

      assert html =~ "Reason code saved."
      assert html =~ "TEST-#{code_suffix}"

      rc = Repo.get_by!(ReasonCode, reason_code: "TEST-#{code_suffix}")
      assert rc.evidence_required == ["signature", "receipt"]
      assert rc.dispute_window_days == 90
    end
  end

  describe "role gating (CS_AGENT — view + file only)" do
    test "cannot see edit-only actions on an existing case" do
      dispute = dispute_fixture()
      operator = operator_fixture("CS_AGENT")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/dps")

      assert has_element?(view, "button", "+ File Dispute")

      html = view |> with_target("#dps-component") |> render_click("open_case", %{"id" => to_string(dispute.dispute_id)})

      refute html =~ "Assign to me"
      refute html =~ ~s(phx-submit="transition")
      refute html =~ ~s(phx-submit="add_note")
    end
  end
end
