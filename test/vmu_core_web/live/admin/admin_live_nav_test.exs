defmodule VmuCoreWeb.Live.Admin.AdminLiveNavTest do
  @moduledoc """
  End-to-end render coverage for the Phase 2 top-nav/contextual-sidebar
  shell (docs/shared/Admin_Menu_Standard.md) — the environment on this
  machine can't boot `mix phx.server` (a sibling path dependency,
  tmsuat_apps-main, isn't checked out here), so this is the closest
  available substitute for actually clicking around in a browser: a real
  LiveView mount against a real Postgres sandbox, asserting on the
  rendered HTML.
  """

  use ExUnit.Case, async: false

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
      username: "nav_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Nav Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  test "default admin page renders the module dock and the Platform Configuration sidebar" do
    operator = operator_fixture("ADMIN")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin")

    assert html =~ "VisionPlus"
    assert html =~ ~s(class="dock-item active")
    assert html =~ "Platform Configuration"
    assert html =~ "System Parameters"
  end

  test "a leaf item's breadcrumb shows both its nav module and its own label" do
    operator = operator_fixture("ADMIN")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/gl")

    assert html =~ "content-breadcrumb"
    assert html =~ "Finance &amp; General Ledger"
    assert html =~ "General Ledger"
  end

  test "a coming-soon-only nav module renders its inert placeholder panel, not access denied" do
    operator = operator_fixture("ADMIN")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/loyalty")

    assert html =~ "Loyalty &amp; Rewards"
    assert html =~ "coming soon"
    assert html =~ "Schemes &amp; Plans"
    assert html =~ "Points Ledger"
    assert html =~ "Redemptions"
    refute html =~ "Access denied"
  end

  test "a coming-soon item inside an otherwise-live nav module renders inert alongside its live siblings" do
    operator = operator_fixture("ADMIN")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/customer")

    assert html =~ "Customers (CIF)"
    assert html =~ "Party 360"
    assert html =~ ~s(class="sidebar-item soon")
    assert html =~ "badge-soon"
  end
end
