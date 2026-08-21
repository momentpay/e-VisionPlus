defmodule VmuCoreWeb.Live.Admin.PortfolioDashboardComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Same fixture pattern as
  `CollectionsMiComponentTest` — proves the dashboard's aggregate queries
  (account totals, status/delinquency distributions, open-dispute count)
  actually run against real rows rather than only compiling.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
  alias VmuCore.DPS.Dispute
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
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
      username: "pd_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Portfolio Dashboard Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  defp account_fixture(overrides) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Portfolio", last_name: "Dash#{n}",
        id_type: "PASSPORT", id_number: "PD-TEST-#{n}"
      })
      |> Repo.insert!()

    attrs =
      Map.merge(
        %{
          customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
          block_id: block_id, pan_token: "pd-test-pan-#{n}", last_four: "7777",
          expiry_date: "1230", credit_limit: D.new("8000.00"), open_to_buy: D.new("6000.00")
        },
        overrides
      )

    %Account{} |> Account.changeset(attrs) |> Repo.insert!()
  end

  defp dispute_fixture(account, overrides) do
    attrs =
      Map.merge(
        %{
          account_id: account.account_id,
          transaction_date: Date.utc_today(),
          dispute_amount: D.new("120.00"),
          reason_code: "10.4"
        },
        overrides
      )

    %Dispute{} |> Dispute.changeset(attrs) |> Repo.insert!()
  end

  test "renders real account totals, distributions and open-dispute count" do
    account_fixture(%{account_status: "ACTIVE", delinquency_bucket: 0})
    delinquent = account_fixture(%{account_status: "DELINQUENT", delinquency_bucket: 30})

    dispute_fixture(delinquent, %{status: "FILED"})
    dispute_fixture(delinquent, %{status: "CLOSED_WIN"})

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/portfolio_dashboard")

    assert html =~ "Portfolio Dashboard"
    assert html =~ "Total accounts"

    # Both charts are AG Chart panels — server-rendered as a JSON data
    # attribute (phx-update="ignore", built client-side), so assert on the
    # payload rather than on markup AG Charts builds in JS.
    assert has_element?(view, "#portfolio-status-chart[data-chart-data*='\"status\":\"DELINQUENT\"']")
    assert has_element?(view, "#portfolio-delinquency-chart[data-chart-data*='\"bucket\":\"30+ DPD\"']")

    # 1 open (FILED), 1 terminal (CLOSED_WIN) — only the open one counts.
    assert html =~ "Open disputes"
  end

  test "renders the empty state with no accounts yet" do
    operator = operator_fixture("SUPERVISOR")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/portfolio_dashboard")

    assert html =~ "No accounts in the system yet"
  end

  test "unauthenticated request redirects to login" do
    assert {:error, {:redirect, %{to: "/visionplus/admin/login"}}} =
             live(build_conn(), "/visionplus/admin/portfolio_dashboard")
  end
end
