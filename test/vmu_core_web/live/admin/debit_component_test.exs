defmodule VmuCoreWeb.Live.Admin.DebitComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 4
  (Debit, D5) — first-ever admin UI test coverage for Debit: account
  creation, funding, card issuance, and activate/block/unblock, all
  end-to-end through the real LiveView. Account creation rewritten for
  Card Products UX Parity Phase 1 (2026-07-28) — a 3-step wizard
  (Customer search+select / Product dropdowns / Review) replacing the
  old flat form that hand-typed SYS/BANK/LOGO/BLOCK IDs and always
  created a brand-new Customer inline.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.{DebitAccount, DebitAccountOpening}
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
      username: "debit_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Debit Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "555555", description: "test", product_type: "DEBIT", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp debit_account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Ui", last_name: "DebitTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    {account, sys_id, bank_id, logo_id, block_id}
  end

  test "wizard customer search matches a combined 'First Last' name, not just one field" do
    # Real bug found live (2026-07-28): searching "Ahmed Al Rashid" (what
    # an operator naturally types) matched neither first_name ("Ahmed")
    # nor last_name ("Al Rashid") alone.
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, _logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "FullName", last_name: "SearchTest#{n}"})
      |> Repo.insert!()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
    view |> element("button[phx-click=debit_new]") |> render_click()

    html =
      view
      |> element("input[phx-keyup=cust_search_wizard]")
      |> render_keyup(%{"value" => "FullName SearchTest#{n}"})

    assert html =~ "FullName"
    assert html =~ "SearchTest#{n}"
    assert html =~ to_string(customer.customer_id)
  end

  test "opening a new debit account for an existing customer via the 3-step wizard" do
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Wizard", last_name: "DebitTest#{n}"})
      |> Repo.insert!()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")

    view |> element("button[phx-click=debit_new]") |> render_click()

    # Step 1 — search and select an existing customer (no more inline
    # customer creation, no more hand-typed SYS/BANK IDs).
    step1_html =
      view
      |> element("input[phx-keyup=cust_search_wizard]")
      |> render_keyup(%{"value" => "DebitTest#{n}"})

    assert step1_html =~ "Wizard"

    view |> element("button[phx-click=select_customer][phx-value-id='#{customer.customer_id}']") |> render_click()

    # Step 2 — Logo/Block dropdowns, not free-text
    step2_html = render(view)
    assert step2_html =~ "Step 2"
    assert step2_html =~ logo_id

    view
    |> form("form[phx-change=wizard_change]", %{"acc" => %{"logo_id" => logo_id}})
    |> render_change()

    view |> element("button[phx-click=wizard_step][phx-value-s='3']") |> render_click()

    # Step 3 — Review, then save
    review_html = render(view)
    assert review_html =~ "Step 3 — Review"
    assert review_html =~ "Wizard"

    # wizard_save lands straight on the new account's detail view (same
    # chain the old create_account_save used) — the customer's name shows
    # in the detail header title.
    html = view |> element("button[phx-click=wizard_save]") |> render_click()
    assert html =~ "Wizard DebitTest#{n} — Debit Account"

    account = Repo.get_by!(DebitAccount, customer_id: customer.customer_id)
    assert D.equal?(account.available_balance, D.new(0))
    assert account.status == "ACTIVE"
  end

  test "funding an account, issuing a card, then activate/block/unblock it end-to-end" do
    {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
    view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()

    view |> element("button[phx-click=open_action][phx-value-a=fund_account]") |> render_click()

    fund_html =
      view
      |> form("form[phx-submit=fund_account_save]", %{
        "funding" => %{"amount" => "250.00", "channel" => "ADMIN_MANUAL"}
      })
      |> render_submit()

    assert fund_html =~ "Account funded: 250.00."
    assert fund_html =~ "250.00"

    # Issue Card lives under the Cards tab (Card Products UX Parity Phase
    # 1b, 2026-07-28) — not visible from the default Overview tab.
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

  test "external funding channel requires a reference" do
    {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
    view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
    view |> element("button[phx-click=open_action][phx-value-a=fund_account]") |> render_click()

    html =
      view
      |> form("form[phx-submit=fund_account_save]", %{
        "funding" => %{"amount" => "100.00", "channel" => "EXTERNAL_BANK_TRANSFER"}
      })
      |> render_submit()

    assert html =~ "A reference is required for this channel."
  end

  describe "Adjustments (Card Products UX Parity Phase 1c, 2026-07-28)" do
    test "a CREDIT adjustment approved by a different supervisor increases the balance" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      maker = operator_fixture("SUPERVISOR")
      checker = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=adjustment]") |> render_click()

      html =
        view
        |> form("form[phx-submit=debit_adjustment_save]", %{
          "adjustment" => %{
            "direction" => "CREDIT", "amount" => "60.00", "reason" => "Goodwill",
            "reference_id" => "CAS-1", "supervisor_id" => checker.username
          }
        })
        |> render_submit()

      assert html =~ "Adjustment posted."
      assert html =~ "60.00"

      updated = Repo.get!(DebitAccount, account.debit_account_id)
      assert D.equal?(updated.available_balance, D.new("60.00"))
    end

    test "the maker cannot approve their own adjustment (4-eyes)" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      maker = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=adjustment]") |> render_click()

      html =
        view
        |> form("form[phx-submit=debit_adjustment_save]", %{
          "adjustment" => %{
            "direction" => "CREDIT", "amount" => "60.00", "reason" => "Self-approve",
            "reference_id" => "CAS-2", "supervisor_id" => maker.username
          }
        })
        |> render_submit()

      assert html =~ "cannot approve your own action"

      updated = Repo.get!(DebitAccount, account.debit_account_id)
      assert D.equal?(updated.available_balance, D.new(0))
    end

    test "a DEBIT adjustment exceeding the available balance fails cleanly" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      maker = operator_fixture("SUPERVISOR")
      checker = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(maker), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=adjustment]") |> render_click()

      html =
        view
        |> form("form[phx-submit=debit_adjustment_save]", %{
          "adjustment" => %{
            "direction" => "DEBIT", "amount" => "10.00", "reason" => "Reverse",
            "reference_id" => "CAS-3", "supervisor_id" => checker.username
          }
        })
        |> render_submit()

      assert html =~ "insufficient funds"
    end
  end

  describe "Account-level parity actions (Card Products UX Parity Phase 1e, 2026-07-28)" do
    test "applying and removing an account block updates status and history" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=apply_block]") |> render_click()

      block_html =
        view
        |> form("form[phx-submit=debit_block_save]", %{
          "action" => %{"block_code" => "F", "reason_code" => "FRAUD_ALERT", "reason_text" => "Suspicious"}
        })
        |> render_submit()

      assert block_html =~ "applied"
      updated = Repo.get!(DebitAccount, account.debit_account_id)
      assert updated.block_code == "F"

      unblock_html =
        view
        |> element("button[phx-click=open_action][phx-value-a=remove_block]")
        |> render_click()

      unblock_html =
        view
        |> form("form[phx-submit=debit_unblock_save]", %{
          "action" => %{"reason_code" => "INVESTIGATION_CLOSED"}
        })
        |> render_submit()

      assert unblock_html =~ "Block removed"
      cleared = Repo.get!(DebitAccount, account.debit_account_id)
      assert is_nil(cleared.block_code)

      view |> element("div[phx-click=detail_tab][phx-value-t='5']") |> render_click()
      history_html = render(view)
      assert history_html =~ "BLOCKED"
      assert history_html =~ "UNBLOCKED"
    end

    test "an address change updates the linked customer and is recorded as a non-monetary event" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=change_address]") |> render_click()

      html =
        view
        |> form("form[phx-submit=debit_nonmon_save]", %{
          "action" => %{
            "event_type" => "address_change", "new_line1" => "789 New Blvd",
            "new_city" => "Dubai", "new_country" => "AE"
          }
        })
        |> render_submit()

      assert html =~ "Address change recorded"

      updated_customer = Repo.get!(Customer, account.customer_id)
      assert updated_customer.address_line1 == "789 New Blvd"

      view |> element("div[phx-click=detail_tab][phx-value-t='5']") |> render_click()
      assert render(view) =~ "ADDRESS_CHANGE"
    end

    test "changing velocity limits persists a structured map and logs a limit_change event" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=change_limits]") |> render_click()

      html =
        view
        |> form("form[phx-submit=debit_limits_save]", %{
          "action" => %{
            "pos_daily_count" => "10", "pos_daily_amount" => "5000",
            "atm_daily_count" => "3", "atm_daily_amount" => "2000"
          }
        })
        |> render_submit()

      assert html =~ "Velocity limits updated"

      updated = Repo.get!(DebitAccount, account.debit_account_id)
      assert updated.velocity_limits["POS"]["daily_count"] == 10
      assert updated.velocity_limits["ATM"]["daily_amount"] == 2000
    end

    test "KYC status can be verified, then reset back to pending" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()

      verify_html = view |> element("button[phx-click=debit_kyc][phx-value-status=VERIFIED]") |> render_click()
      assert verify_html =~ "KYC status set to VERIFIED"

      verified = Repo.get!(DebitAccount, account.debit_account_id)
      assert verified.kyc_status == "VERIFIED"
      assert verified.kyc_verified_at

      reset_html = view |> element("button[phx-click=debit_kyc][phx-value-status=PENDING]") |> render_click()
      assert reset_html =~ "KYC status set to PENDING"

      reset = Repo.get!(DebitAccount, account.debit_account_id)
      assert reset.kyc_status == "PENDING"
      assert is_nil(reset.kyc_verified_at)
    end

    test "supplementary card can be issued via the card-type dropdown" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='3']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=issue_card]") |> render_click()

      html =
        view
        |> form("form[phx-submit=issue_card_save]", %{"card" => %{"card_type" => "SUPPLEMENTARY"}})
        |> render_submit()

      assert html =~ "SUPPLEMENTARY card issued (INACTIVE)."
    end

    test "per-card channel controls can be set, overriding product defaults" do
      {account, _sys_id, _bank_id, _logo_id, _block_id} = debit_account_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/debit")
      view |> element("button[phx-click=view_account][phx-value-id='#{account.debit_account_id}']") |> render_click()
      view |> element("div[phx-click=detail_tab][phx-value-t='3']") |> render_click()
      view |> element("button[phx-click=open_action][phx-value-a=issue_card]") |> render_click()

      view
      |> form("form[phx-submit=issue_card_save]", %{"card" => %{"card_type" => "PRIMARY"}})
      |> render_submit()

      view |> element("button[phx-click=open_channels]") |> render_click()

      html =
        view
        |> form("form[phx-submit=card_channels_save]", %{
          "ecom_enabled" => "false", "atm_enabled" => "true",
          "contactless_enabled" => "", "intl_enabled" => "false"
        })
        |> render_submit()

      assert html =~ "Channel controls updated."

      [card] = VmuCore.CTA.Cards.by_debit_account(account.debit_account_id)
      assert card.ecom_enabled == false
      assert card.atm_enabled == true
      assert is_nil(card.contactless_enabled)
      assert card.intl_enabled == false
    end
  end
end
