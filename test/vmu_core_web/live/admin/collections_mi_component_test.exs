defmodule VmuCoreWeb.Live.Admin.CollectionsMiComponentTest do
  @moduledoc """
  Live test for the Collections MI dashboard (FR-COL-025). Real Postgres
  via Sandbox, no mocking. Same fixture pattern as `ColComponentTest`.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
  alias VmuCore.COL.DpdBucketHistory
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
      username: "mi_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "MI Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  defp parameter_hierarchy_fixture do
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

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Mi", last_name: "UiTest#{n}",
        id_type: "PASSPORT", id_number: "MI-UI-TEST-#{n}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "mi-ui-test-pan-#{n}", last_four: "5555",
      expiry_date: "1230", credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  test "renders the roll/cure table for a real seeded transition" do
    account = account_fixture()
    today = Date.utc_today()

    %DpdBucketHistory{}
    |> DpdBucketHistory.changeset(%{account_id: account.account_id, eod_date: today, old_bucket: 0, new_bucket: 30})
    |> Repo.insert!()

    operator = operator_fixture("SUPERVISOR")
    {:ok, view, html} = live(authed_conn(operator), "/visionplus/admin/collections_mi")

    assert html =~ "Collections MI"
    assert has_element?(view, "td", "30")

    rendered =
      view
      |> form("form[phx-change=filter]", %{
        "from_date" => Date.to_iso8601(Date.add(today, -1)), "to_date" => Date.to_iso8601(Date.add(today, 1))
      })
      |> render_change()

    assert rendered =~ "1"
  end

  test "unauthenticated request redirects to login" do
    assert {:error, {:redirect, %{to: "/visionplus/admin/login"}}} =
             live(build_conn(), "/visionplus/admin/collections_mi")
  end
end
