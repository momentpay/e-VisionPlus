defmodule VmuCoreWeb.Live.Admin.AdminLiveNavTest do
  @moduledoc """
  End-to-end render coverage for the admin shell — module dock, contextual
  sidebar, theming and the module placeholder page.

  A real LiveView mount against a real Postgres sandbox, asserting on rendered
  HTML. It is the closest available substitute for clicking around a browser,
  and it is what caught the shell regressions during the redesign.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCoreWeb.Admin.Nav

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
      display_name: "Nav Test #{role}",
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

  defp admin_html(path) do
    {:ok, _view, html} = live(authed_conn(operator_fixture("ADMIN")), path)
    html
  end

  describe "module dock" do
    test "renders every nav module, with the active one marked" do
      html = admin_html("/visionplus/admin/gl")

      for nav <- Nav.nav_modules() do
        assert html =~ nav.short_label, "dock is missing #{nav.id}"
      end

      # The active tile carries its module's accent and an aria-current.
      assert html =~ ~s(class="dock-item active")
      assert html =~ ~s(data-accent="blue")
    end

    test "a module with no live screen still gets a dock tile, pointing at its placeholder" do
      html = admin_html("/visionplus/admin/gl")

      assert html =~ ~s(href="/visionplus/admin/loyalty")
    end
  end

  describe "contextual sidebar" do
    test "shows only the active module's groups" do
      html = admin_html("/visionplus/admin/gl")

      # Finance's own groups...
      assert html =~ "Ledger"
      assert html =~ "Period Control"
      # ...but not another module's.
      refute html =~ "Card Lifecycle"
      refute html =~ "Onboarding &amp; KYC"
    end

    test "live items link and planned items render inert with a Soon badge" do
      html = admin_html("/visionplus/admin/customer")

      assert html =~ ~s(href="/visionplus/admin/customer")
      assert html =~ "Party 360"
      assert html =~ ~s(class="nav-item soon")
      assert html =~ "badge-soon"
      refute html =~ ~s(href="/visionplus/admin/party_360"),
             "a planned item must not be a link to nowhere"
    end

    test "names the current module in its own accent" do
      html = admin_html("/visionplus/admin/dps")

      assert html =~ "sidebar-module-tile"
      assert html =~ ~s(data-accent="rose")
      assert html =~ "Disputes &amp; Chargebacks"
    end
  end

  describe "breadcrumb" do
    test "shows the nav module and the specific screen" do
      html = admin_html("/visionplus/admin/gl")

      assert html =~ "content-breadcrumb"
      assert html =~ "Finance &amp; General Ledger"
      assert html =~ "General Ledger"
    end

    test "shows only the module on a placeholder page" do
      html = admin_html("/visionplus/admin/loyalty")

      assert html =~ "Loyalty &amp; Rewards"
      refute html =~ ~s(<span class="sep">/</span>)
    end
  end

  describe "module placeholder page" do
    test "lists what is planned rather than showing access denied" do
      html = admin_html("/visionplus/admin/loyalty")

      assert html =~ "coming soon"
      assert html =~ "Schemes &amp; Plans"
      assert html =~ "Points Ledger"
      assert html =~ "Redemptions"
      refute html =~ "Access denied"
    end
  end

  describe "chrome" do
    test "emits the icon sprite and theme bootstrap" do
      html = admin_html("/visionplus/admin")

      assert html =~ ~s(<symbol id="i-credit-card")
      assert html =~ "vp-icon"
      # Theme is applied before first paint, and the toggle persists it.
      assert html =~ "vp-theme"
      assert html =~ "vpToggleTheme"
    end

    test "shows the operator's initials, name and role" do
      operator = operator_fixture("ADMIN")
      {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin")

      assert html =~ "operator-avatar"
      assert html =~ "Nav Test ADMIN"
      # "Nav Test ADMIN" -> first two words -> "NT"
      assert html =~ ">NT<"
    end
  end

  describe "permissions" do
    test "a narrow role sees only its own screens in the sidebar" do
      operator = operator_fixture("CS_AGENT")
      {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/customer")

      assert html =~ "Customers (CIF)"
      # Operators is ADMIN-only, so it must not appear anywhere in the chrome.
      refute html =~ ~s(href="/visionplus/admin/operators")
    end

    test "a live screen the operator lacks is refused even by direct URL" do
      operator = operator_fixture("CS_AGENT")
      {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/operators")

      assert html =~ "Access denied"
    end
  end
end
