defmodule VmuCoreWeb.Live.Admin.ArrangementDeepLinkTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Koṣa domain-model alignment
  (2026-07-28), follow-up — "View in X" links from the Arrangements
  panels used to land on the bare module list, not the specific record's
  detail page. Covers the `?view=<id>` deep-link mechanism
  (`AdminLive.handle_params/3` -> `deep_link_id` assign -> each target
  component's `update/2`) for both a direct-id product (Credit) and the
  HCS company-resolution path (an employee-card arrangement's view_ref
  resolves to its parent company's id, since HCS has no standalone
  employee-card detail view).
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
  alias VmuCore.HCS.{CompanyOnboarding}
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
      username: "deep_link_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Deep Link Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  test "?view=<account_id> on /visionplus/admin/account opens that account's detail page directly" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "DeepLink", last_name: "CreditTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "deep-link-credit-#{n}", last_four: "4242",
        expiry_date: "1230", credit_limit: D.new("5000.00")
      })
      |> Repo.insert()

    operator = operator_fixture("SUPERVISOR")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/account?view=#{account.account_id}")

    # Detail mode shows the customer name in the header and a "Back to
    # List" action that only exists in :detail mode — the list mode does not.
    assert html =~ "DeepLink"
    assert html =~ "Back to List"
  end

  test "?view=<company_id> on /visionplus/admin/hcs opens that company's detail page directly" do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    company_customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "DeepLink", last_name: "CorpTest#{n}"})
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: company_customer.customer_id, sys_id: sys_id, bank_id: bank_id,
          logo_id: logo_id, block_id: block_id, pan_token: "deep-link-facility-#{n}",
          last_four: "0000", expiry_date: "0000", credit_limit: D.new("50000.00")
        },
        company_attrs: %{
          company_code: "DLNK#{n}", company_name: "Deep Link Co #{n}",
          registration_no: "REG-DLNK-#{n}", liability_model: "CENTRAL", credit_limit: D.new("50000.00")
        }
      })

    operator = operator_fixture("SUPERVISOR")
    {:ok, _view, html} = live(authed_conn(operator), "/visionplus/admin/hcs?view=#{company.id}")

    assert html =~ "Deep Link Co #{n}"
    assert html =~ "Back to list"
  end
end
