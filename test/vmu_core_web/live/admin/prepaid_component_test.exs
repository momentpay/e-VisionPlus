defmodule VmuCoreWeb.Live.Admin.PrepaidComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 5
  (Prepaid, P5) — first-ever admin UI test coverage for Prepaid: account
  creation, loading, card issuance, and activate/block/unblock, all
  end-to-end through the real LiveView.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.{PrepaidAccount, PrepaidAccountOpening}
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
      username: "prepaid_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Prepaid Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test", product_type: "PREPAID", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp prepaid_account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Ui", last_name: "PrepaidTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    {account, sys_id, bank_id, logo_id, block_id}
  end

  test "creating a new prepaid account via the admin form" do
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/prepaid")

    view |> element("button[phx-click=open_action][phx-value-a=create_account]") |> render_click()

    html =
      view
      |> form("form[phx-submit=create_account_save]", %{
        "account" => %{
          "first_name" => "New", "last_name" => "Customer",
          "sys_id" => sys_id, "bank_id" => bank_id, "logo_id" => logo_id, "block_id" => block_id
        }
      })
      |> render_submit()

    assert html =~ "New Customer"

    account = Repo.get_by!(PrepaidAccount, sys_id: sys_id, bank_id: bank_id)
    assert account.status == "ACTIVE"
  end

  test "loading an account, issuing a card, then activate/block/unblock it end-to-end" do
    {account, _sys_id, _bank_id, _logo_id, _block_id} = prepaid_account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/prepaid")
    view |> element("button[phx-click=view_account][phx-value-id='#{account.prepaid_account_id}']") |> render_click()

    view |> element("button[phx-click=open_action][phx-value-a=load_account]") |> render_click()

    load_html =
      view
      |> form("form[phx-submit=load_account_save]", %{
        "load" => %{"amount" => "250.00", "channel" => "ADMIN_MANUAL"}
      })
      |> render_submit()

    assert load_html =~ "Account loaded: 250.00."
    assert load_html =~ "250.00"

    view |> element("button[phx-click=open_action][phx-value-a=issue_card]") |> render_click()

    card_html =
      view
      |> form("form[phx-submit=issue_card_save]", %{"card" => %{"card_type" => "PRIMARY"}})
      |> render_submit()

    assert card_html =~ "PRIMARY card issued (INACTIVE)."

    activate_html = view |> element("button[phx-click=card_activate]") |> render_click()
    assert activate_html =~ "Card activated."

    block_html = view |> element("button[phx-click=card_block]") |> render_click()
    assert block_html =~ "Card blocked."

    unblock_html = view |> element("button[phx-click=card_unblock]") |> render_click()
    assert unblock_html =~ "Card unblocked."
  end

  test "external load channel requires a reference" do
    {account, _sys_id, _bank_id, _logo_id, _block_id} = prepaid_account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/prepaid")
    view |> element("button[phx-click=view_account][phx-value-id='#{account.prepaid_account_id}']") |> render_click()
    view |> element("button[phx-click=open_action][phx-value-a=load_account]") |> render_click()

    html =
      view
      |> form("form[phx-submit=load_account_save]", %{
        "load" => %{"amount" => "100.00", "channel" => "EXTERNAL_BANK_TRANSFER"}
      })
      |> render_submit()

    assert html =~ "A reference is required for this channel."
  end

  test "ledger history shows a LOAD row with the correct remaining amount" do
    {account, _sys_id, _bank_id, _logo_id, _block_id} = prepaid_account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/prepaid")
    view |> element("button[phx-click=view_account][phx-value-id='#{account.prepaid_account_id}']") |> render_click()
    view |> element("button[phx-click=open_action][phx-value-a=load_account]") |> render_click()

    html =
      view
      |> form("form[phx-submit=load_account_save]", %{
        "load" => %{"amount" => "75.00", "channel" => "ADMIN_MANUAL"}
      })
      |> render_submit()

    assert html =~ "LOAD"
    assert D.equal?(
             VmuCore.CMS.PrepaidLedger.balance(account.prepaid_account_id),
             D.new("75.00")
           )
  end
end
