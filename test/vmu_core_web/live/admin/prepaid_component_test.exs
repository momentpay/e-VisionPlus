defmodule VmuCoreWeb.Live.Admin.PrepaidComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 5
  (Prepaid, P5) — first-ever admin UI test coverage for Prepaid: account
  creation, loading, card issuance, and activate/block/unblock, all
  end-to-end through the real LiveView. Account creation rewritten for
  Card Products UX Parity Phase 2 (2026-07-28) — same 3-step wizard
  shape as Debit's Phase 1a.
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

  test "opening a new prepaid account for an existing customer via the 3-step wizard" do
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Wizard", last_name: "PrepaidTest#{n}"})
      |> Repo.insert!()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/prepaid")

    view |> element("button[phx-click=prepaid_new]") |> render_click()

    view
    |> element("input[phx-keyup=cust_search_wizard]")
    |> render_keyup(%{"value" => "PrepaidTest#{n}"})

    view |> element("button[phx-click=select_customer][phx-value-id='#{customer.customer_id}']") |> render_click()

    step2_html = render(view)
    assert step2_html =~ "Step 2"
    assert step2_html =~ logo_id

    view
    |> form("form[phx-change=wizard_change]", %{"acc" => %{"logo_id" => logo_id}})
    |> render_change()

    view |> element("button[phx-click=wizard_step][phx-value-s='3']") |> render_click()

    review_html = render(view)
    assert review_html =~ "Step 3 — Review"
    assert review_html =~ "Wizard"

    html = view |> element("button[phx-click=wizard_save]") |> render_click()
    assert html =~ "Wizard PrepaidTest#{n}"

    account = Repo.get_by!(PrepaidAccount, customer_id: customer.customer_id)
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

    # Issue Card lives under the Cards tab (Card Products UX Parity Phase
    # 2b, 2026-07-28) — not visible from the default Overview tab.
    view |> element("div[phx-click=detail_tab][phx-value-t='3']") |> render_click()
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

    view
    |> form("form[phx-submit=load_account_save]", %{
      "load" => %{"amount" => "75.00", "channel" => "ADMIN_MANUAL"}
    })
    |> render_submit()

    # Ledger rows live under the Ledger History tab (Card Products UX
    # Parity Phase 2b, 2026-07-28) — not the default Overview tab.
    html = view |> element("div[phx-click=detail_tab][phx-value-t='2']") |> render_click()

    assert html =~ "LOAD"
    assert D.equal?(
             VmuCore.CMS.PrepaidLedger.balance(account.prepaid_account_id),
             D.new("75.00")
           )
  end

  describe "Adjustments (Card Products UX Parity Phase 2c, 2026-07-28)" do
    test "a CREDIT adjustment approved by a different supervisor increases the balance" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = prepaid_account_fixture()
      maker = operator_fixture("SUPERVISOR")
      checker = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/prepaid")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.prepaid_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=adjustment]") |> render_click()

      html =
        view
        |> form("form[phx-submit=prepaid_adjustment_save]", %{
          "adjustment" => %{
            "direction" => "CREDIT", "amount" => "60.00", "reason" => "Goodwill",
            "reference_id" => "CAS-1", "supervisor_id" => checker.username
          }
        })
        |> render_submit()

      assert html =~ "Adjustment posted."
      assert html =~ "60.00"

      assert D.equal?(
               VmuCore.CMS.PrepaidLedger.balance(account.prepaid_account_id),
               D.new("60.00")
             )
    end

    test "the maker cannot approve their own adjustment (4-eyes)" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = prepaid_account_fixture()
      maker = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/prepaid")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.prepaid_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=adjustment]") |> render_click()

      html =
        view
        |> form("form[phx-submit=prepaid_adjustment_save]", %{
          "adjustment" => %{
            "direction" => "CREDIT", "amount" => "60.00", "reason" => "Self-approve",
            "reference_id" => "CAS-2", "supervisor_id" => maker.username
          }
        })
        |> render_submit()

      assert html =~ "cannot approve your own action"

      assert D.equal?(VmuCore.CMS.PrepaidLedger.balance(account.prepaid_account_id), D.new(0))
    end

    test "a DEBIT adjustment exceeding the available balance fails cleanly" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = prepaid_account_fixture()
      maker = operator_fixture("SUPERVISOR")
      checker = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/prepaid")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.prepaid_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=adjustment]") |> render_click()

      html =
        view
        |> form("form[phx-submit=prepaid_adjustment_save]", %{
          "adjustment" => %{
            "direction" => "DEBIT", "amount" => "10.00", "reason" => "Reverse",
            "reference_id" => "CAS-3", "supervisor_id" => checker.username
          }
        })
        |> render_submit()

      assert html =~ "insufficient funds"
    end
  end
end
