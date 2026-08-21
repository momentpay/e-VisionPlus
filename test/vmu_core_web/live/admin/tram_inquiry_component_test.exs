defmodule VmuCoreWeb.Live.Admin.TramInquiryComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. This screen had no test coverage
  at all before the Admin_Detail_UX_Philosophy rollout — which is exactly
  the gap that let its Identifiers/Event Timeline tables get converted to
  AG Grid without anyone noticing they never needed it.

  Covers both halves of the philosophy doc:
    * §1 — the two small fixed-shape sub-tables render as plain HTML,
      while the platform-wide Results table stays an AG Grid.
    * §2/§3 — the Detail action opens the shared drawer, driven through
      `with_target/2` rather than a DOM button lookup (the AG Grid
      actions cell is client-rendered and invisible to LiveViewTest).
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.TRAMS.{Transaction, TransactionEvent, TransactionIdentifier}
  alias Decimal, as: D

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
      username: "tram_ui_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Tram UI Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  defp transaction_fixture do
    n = System.unique_integer([:positive])

    txn =
      %Transaction{}
      |> Transaction.changeset(%{
        # pan_token is validated at exactly 64 chars (a hash), so pad rather
        # than inventing a short token the changeset would reject.
        pan_token: String.pad_leading("#{n}", 64, "0"),
        transaction_type: "PURCHASE",
        amount: D.new("125.50"),
        currency: "AED",
        state: "POSTED",
        merchant_name: "Tram Test Merchant #{n}",
        transaction_date: DateTime.utc_now() |> DateTime.truncate(:second)
      })
      |> Repo.insert!()

    %TransactionIdentifier{}
    |> TransactionIdentifier.changeset(%{
      transaction_id: txn.transaction_id, stan: "142338", rrn: "RRN#{n}", source: "authorization"
    })
    |> Repo.insert!()

    %TransactionEvent{}
    |> TransactionEvent.changeset(%{
      transaction_id: txn.transaction_id, seq: 1, event_type: "authorization_approved",
      actor: "system", occurred_at: DateTime.utc_now()
    })
    |> Repo.insert!()

    txn
  end

  test "the Detail action opens the drawer with the transaction's identifiers and events" do
    txn = transaction_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/tram_inquiry")

    # Drawer is mounted but closed — it stays in the DOM so the slide
    # transition has something to animate from (philosophy doc §2).
    assert has_element?(view, "#tram-detail-drawer")
    refute html =~ "is-open"

    # The Detail button lives in an AG Grid actions cell, built client-side
    # inside phx-update="ignore" — LiveViewTest cannot see or click it, so
    # target the LiveComponent directly. This is the whole technique.
    html =
      view
      |> with_target("#tram-inquiry-component")
      |> render_click("show_detail", %{"id" => txn.transaction_id})

    assert html =~ "is-open", "drawer should be open after show_detail"
    assert html =~ "Identifiers"
    assert html =~ "142338"
    assert html =~ "authorization_approved"

    # §1: those two sub-tables are plain HTML, not AG Grid panels.
    refute has_element?(view, "#tram-detail-identifiers-grid")
    refute has_element?(view, "#tram-detail-events-grid")

    # ...while the platform-wide results table correctly stays an AG Grid.
    assert has_element?(view, "#tram-inquiry-results-grid")
  end

  test "closing the drawer leaves the results list in place" do
    txn = transaction_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/tram_inquiry")

    view |> with_target("#tram-inquiry-component") |> render_click("show_detail", %{"id" => txn.transaction_id})
    html = view |> with_target("#tram-inquiry-component") |> render_click("close_detail", %{})

    refute html =~ "is-open"
    # The point of a drawer over a page swap: the list never went away.
    assert has_element?(view, "#tram-inquiry-results-grid")
  end

  test "unauthenticated request redirects to login" do
    assert {:error, {:redirect, %{to: "/visionplus/admin/login"}}} =
             live(build_conn(), "/visionplus/admin/tram_inquiry")
  end
end
