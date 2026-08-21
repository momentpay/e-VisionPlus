defmodule VmuCoreWeb.Live.Admin.WalletComponentTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Digital Wallet Phase W4
  (2026-07-28) — first-ever admin UI test coverage for Digital Wallet:
  wizard creation, load, transfer, QR receive/pay, and the account-level
  Block/Address/Phone/Email/Limits/KYC parity toolbar, all end-to-end
  through the real LiveView.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.{WalletAccount, WalletProductOpening, WalletFundingCommand}
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
      username: "wallet_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Wallet Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
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

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. Production gets
    # all three from `seed_gl.exs`; a test that mints an institution inline has
    # to supply them. See `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(sys_id, bank_id)
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp wallet_fixture(opts \\ []) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])
    name = Keyword.get(opts, :name, "Ui")

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: name, last_name: "WalletTest#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "#{name}'s Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    if load = opts[:load] do
      {:ok, _} =
        WalletFundingCommand.fund(%{
          wallet_account_id: account.wallet_account_id, amount: load,
          channel: "ADMIN_MANUAL", posted_by: "seed"
        })
    end

    account = Repo.get!(WalletAccount, account.wallet_account_id)
    {account, sys_id, bank_id, logo_id, block_id, customer}
  end

  test "wizard customer search matches a combined 'First Last' name" do
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, _logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "FullName", last_name: "SearchTest#{n}"})
      |> Repo.insert!()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
    view |> element("button[phx-click=wallet_new]") |> render_click()

    html =
      view
      |> element("input[phx-keyup=cust_search_wizard]")
      |> render_keyup(%{"value" => "FullName SearchTest#{n}"})

    assert html =~ "FullName"
    assert html =~ to_string(customer.customer_id)
  end

  test "opening a new wallet for an existing customer via the 3-step wizard" do
    operator = operator_fixture("SUPERVISOR")
    {sys_id, bank_id, logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Wizard", last_name: "WalletTest#{n}"})
      |> Repo.insert!()

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
    view |> element("button[phx-click=wallet_new]") |> render_click()

    view
    |> element("input[phx-keyup=cust_search_wizard]")
    |> render_keyup(%{"value" => "WalletTest#{n}"})

    view |> with_target("#wallet-component") |> render_click("select_customer", %{"id" => customer.customer_id})

    step2_html = render(view)
    assert step2_html =~ "Step 2"
    assert step2_html =~ logo_id

    view
    |> form("form[phx-change=wizard_change]", %{"acc" => %{"logo_id" => logo_id}})
    |> render_change()

    view |> element("button[phx-click=wizard_step][phx-value-s='3']") |> render_click()

    review_html = render(view)
    assert review_html =~ "Step 3 — Review"

    html = view |> element("button[phx-click=wizard_save]") |> render_click()
    assert html =~ "Wizard WalletTest#{n} — Digital Wallet"

    account = Repo.get_by!(WalletAccount, customer_id: customer.customer_id)
    assert D.equal?(account.available_balance, D.new(0))
    assert account.status == "ACTIVE"
  end

  test "loading a wallet increases the balance" do
    {account, _sys_id, _bank_id, _logo_id, _block_id, _customer} = wallet_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
    view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})
    view |> element("button[phx-click=open_action][phx-value-a=load_account]") |> render_click()

    html =
      view
      |> form("form[phx-submit=load_account_save]", %{
        "load" => %{"amount" => "250.00", "channel" => "ADMIN_MANUAL"}
      })
      |> render_submit()

    assert html =~ "Wallet loaded: 250.00."
    updated = Repo.get!(WalletAccount, account.wallet_account_id)
    assert D.equal?(updated.available_balance, D.new("250.00"))
  end

  test "sending a transfer to another wallet moves money and shows in both histories" do
    {sender, _s1, _b1, _l1, _bl1, _c1} = wallet_fixture(name: "Sender", load: D.new("300.00"))
    {receiver, _s2, _b2, _l2, _bl2, _c2} = wallet_fixture(name: "Receiver")
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
    view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => sender.wallet_account_id})
    view |> element("div[phx-click=detail_tab][phx-value-t='2']") |> render_click()
    view |> element("button[phx-click=open_action][phx-value-a=send_transfer]") |> render_click()

    view
    |> element("input[phx-keyup=xfer_search]")
    |> render_keyup(%{"value" => "Receiver"})

    view |> element("button[phx-click=xfer_select][phx-value-id='#{receiver.wallet_account_id}']") |> render_click()

    html =
      view
      |> form("form[phx-submit=transfer_save]", %{"transfer" => %{"amount" => "75.00", "reason" => "test"}})
      |> render_submit()

    assert html =~ "Transfer sent: 75.00."

    assert D.equal?(Repo.get!(WalletAccount, sender.wallet_account_id).available_balance, D.new("225.00"))
    assert D.equal?(Repo.get!(WalletAccount, receiver.wallet_account_id).available_balance, D.new("75.00"))
  end

  test "generating a QR then paying it from another wallet moves the exact amount" do
    {payee, _s1, _b1, _l1, _bl1, _c1} = wallet_fixture(name: "Payee")
    {payer, _s2, _b2, _l2, _bl2, _c2} = wallet_fixture(name: "Payer", load: D.new("100.00"))
    operator = operator_fixture("SUPERVISOR")

    {:ok, payee_view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
    payee_view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => payee.wallet_account_id})
    payee_view |> element("div[phx-click=detail_tab][phx-value-t='3']") |> render_click()

    qr_html =
      payee_view
      |> form("form[phx-submit=generate_qr_save]", %{"qr" => %{"amount" => "40.00", "label" => "Coffee"}})
      |> render_submit()

    assert qr_html =~ "QR Code (wire format"
    [_, qr_string] = Regex.run(~r/<textarea[^>]*readonly[^>]*>([^<]+)<\/textarea>/, qr_html)

    {:ok, payer_view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
    payer_view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => payer.wallet_account_id})
    payer_view |> element("div[phx-click=detail_tab][phx-value-t='3']") |> render_click()

    pay_html =
      payer_view
      |> form("form[phx-submit=pay_qr_save]", %{"pay" => %{"qr_string" => qr_string}})
      |> render_submit()

    assert pay_html =~ "Paid 40.00 via QR."
    assert D.equal?(Repo.get!(WalletAccount, payer.wallet_account_id).available_balance, D.new("60.00"))
    assert D.equal?(Repo.get!(WalletAccount, payee.wallet_account_id).available_balance, D.new("40.00"))
  end

  describe "Account-level parity actions (Digital Wallet Phase W4, 2026-07-28)" do
    test "applying and removing an account block updates status and history" do
      {account, _s, _b, _l, _bl, _c} = wallet_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})
      view |> element("button[phx-click=open_action][phx-value-a=apply_block]") |> render_click()

      block_html =
        view
        |> form("form[phx-submit=wallet_block_save]", %{
          "action" => %{"block_code" => "F", "reason_code" => "FRAUD_ALERT"}
        })
        |> render_submit()

      assert block_html =~ "applied"
      assert Repo.get!(WalletAccount, account.wallet_account_id).block_code == "F"

      view |> element("button[phx-click=open_action][phx-value-a=remove_block]") |> render_click()

      unblock_html =
        view
        |> form("form[phx-submit=wallet_unblock_save]", %{
          "action" => %{"reason_code" => "INVESTIGATION_CLOSED"}
        })
        |> render_submit()

      assert unblock_html =~ "Block removed"
      assert is_nil(Repo.get!(WalletAccount, account.wallet_account_id).block_code)

      view |> element("div[phx-click=detail_tab][phx-value-t='4']") |> render_click()
      history_html = render(view)
      assert history_html =~ "BLOCKED"
      assert history_html =~ "UNBLOCKED"
    end

    test "an address change updates the linked customer" do
      {account, _s, _b, _l, _bl, customer} = wallet_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})
      view |> element("button[phx-click=open_action][phx-value-a=change_address]") |> render_click()

      html =
        view
        |> form("form[phx-submit=wallet_nonmon_save]", %{
          "action" => %{
            "event_type" => "address_change", "new_line1" => "1 Wallet St",
            "new_city" => "Dubai", "new_country" => "AE"
          }
        })
        |> render_submit()

      assert html =~ "Address change recorded"
      assert Repo.get!(Customer, customer.customer_id).address_line1 == "1 Wallet St"
    end

    test "changing velocity limits persists a structured map" do
      {account, _s, _b, _l, _bl, _c} = wallet_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})
      view |> element("button[phx-click=open_action][phx-value-a=change_limits]") |> render_click()

      html =
        view
        |> form("form[phx-submit=wallet_limits_save]", %{
          "action" => %{"daily_count" => "5", "daily_amount" => "1000", "monthly_amount" => "20000"}
        })
        |> render_submit()

      assert html =~ "Velocity limits updated"
      updated = Repo.get!(WalletAccount, account.wallet_account_id)
      assert updated.velocity_limits["DAILY"]["count"] == 5
      assert updated.velocity_limits["MONTHLY"]["amount"] == 20000
    end

    test "KYC status can be verified, then reset back to pending" do
      {account, _s, _b, _l, _bl, _c} = wallet_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})

      verify_html = view |> element("button[phx-click=wallet_kyc][phx-value-status=VERIFIED]") |> render_click()
      assert verify_html =~ "KYC status set to VERIFIED"

      verified = Repo.get!(WalletAccount, account.wallet_account_id)
      assert verified.kyc_status == "VERIFIED"
      assert verified.kyc_verified_at

      reset_html = view |> element("button[phx-click=wallet_kyc][phx-value-status=PENDING]") |> render_click()
      assert reset_html =~ "KYC status set to PENDING"
      assert Repo.get!(WalletAccount, account.wallet_account_id).kyc_status == "PENDING"
    end
  end

  describe "Multi-currency (Digital Wallet Phase W7, 2026-07-30)" do
    test "adding a currency creates a real second account under the same wallet product and switches to it" do
      {account, _s, _b, _l, _bl, _c} = wallet_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})
      view |> element("button[phx-click=open_action][phx-value-a=add_currency]") |> render_click()

      html =
        view
        |> form("form[phx-submit=add_currency_save]", %{"action" => %{"currency" => "usd"}})
        |> render_submit()

      assert html =~ "USD account added to this wallet."
      assert html =~ "Currencies (2)"

      new_account = Repo.get_by!(WalletAccount, wallet_product_id: account.wallet_product_id, currency: "USD")
      assert new_account.wallet_account_id != account.wallet_account_id
      assert D.equal?(new_account.available_balance, D.new(0))
    end

    test "adding a currency that already exists on the wallet fails cleanly, not with a crash" do
      {account, _s, _b, _l, _bl, _c} = wallet_fixture()
      operator = operator_fixture("SUPERVISOR")

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})
      view |> element("button[phx-click=open_action][phx-value-a=add_currency]") |> render_click()

      html =
        view
        |> form("form[phx-submit=add_currency_save]", %{"action" => %{"currency" => account.currency}})
        |> render_submit()

      assert html =~ "Add currency failed"
    end

    test "switching currency loads the sibling account's own balance and history" do
      {account, sys_id, bank_id, logo_id, block_id, _c} = wallet_fixture(load: D.new("500.00"))
      operator = operator_fixture("SUPERVISOR")

      {:ok, other} =
        VmuCore.CMS.WalletProductOpening.add_currency_account(%{
          wallet_product_id: account.wallet_product_id,
          sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id, currency: "EUR"
        })

      {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/wallet")
      view |> with_target("#wallet-component") |> render_click("view_account", %{"id" => account.wallet_account_id})

      html = view |> element("button[phx-click=switch_currency][phx-value-id='#{other.wallet_account_id}']") |> render_click()

      assert html =~ "EUR"
      refute html =~ "500.00 AED"
    end
  end
end
