defmodule VmuCoreWeb.Live.Admin.AgGridPilotTest do
  @moduledoc """
  End-to-end coverage for Phase 5 of the AG Grid rollout — the pilot that
  established the `<.ag_grid>` contract (`VmuCoreWeb.Components.AgGrid`,
  `assets/js/hooks/ag_grid_hook.js`) on three real screens: Audit Trail,
  Service Accounts, Collections MI.

  Real LiveView mounts against a real Postgres sandbox, asserting the grid
  container renders with the right id, that its `data-columns`/`data-rows`
  JSON attributes carry the expected shape, and that conditional/typed
  columns (badge classField, actions whenField) are wired correctly — the
  parts a plain "does the page load" smoke test would not catch.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, AuditLog, Operator, ServiceAccounts}

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
      username: "ag_grid_pilot_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "AG Grid Pilot #{role}",
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

  describe "Audit Trail" do
    test "renders the grid with a real entry, badge class resolved server-side" do
      operator = operator_fixture("ADMIN")

      AuditLog.record(operator, "customer_pii_view", "cust-#{System.unique_integer([:positive])}")

      {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/audit_log")

      assert html =~ ~s(id="audit-log-grid")
      assert html =~ ~s(data-paginate="false")
      # "customer_pii_view" resolves through action_class/1 to "warning",
      # so the row's action_class field must carry the real CSS class
      # (badge-warning) — not the bare "warning" the pre-conversion
      # markup emitted, which matched no rule in admin.css at all.
      assert has_element?(view, ~s(#audit-log-grid[data-rows*='"action_class":"badge-warning"']))
    end
  end

  describe "Service Accounts" do
    test "grid renders; Revoke is wired to the active row via whenField/whenValue" do
      operator = operator_fixture("ADMIN")

      {:ok, account, _token} =
        ServiceAccounts.create(%{
          "name" => "ag-grid-pilot-test-#{System.unique_integer([:positive])}",
          "scopes" => ["kyc:read"],
          "created_by" => operator.username
        })

      {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/service_accounts")

      assert html =~ ~s(id="service-accounts-grid")
      assert html =~ account.name
      assert has_element?(view, ~s(#service-accounts-grid[data-rows*='"status":"ACTIVE"']))
      assert has_element?(view, ~s(#service-accounts-grid[data-columns*='"event":"revoke"']))
      assert has_element?(view, ~s(#service-accounts-grid[data-columns*='"whenField":"status"']))
      assert has_element?(view, ~s(#service-accounts-grid[data-columns*='"whenValue":"ACTIVE"']))
    end

    test "a non-ADMIN sees the module gated, not the grid" do
      operator = operator_fixture("CS_AGENT")
      {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/service_accounts")

      refute html =~ ~s(id="service-accounts-grid")
    end
  end

  describe "Collections MI" do
    test "roll/cure grid renders with the right columns and no server-side pagination" do
      operator = operator_fixture("SUPERVISOR")
      {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/collections_mi")

      assert html =~ ~s(id="collections-mi-roll-cure-grid")
      assert html =~ ~s(data-paginate="false")
      assert html =~ "Roll rate / cure rate by DPD bucket"
    end
  end
end
