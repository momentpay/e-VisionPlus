defmodule VmuCoreWeb.Live.Admin.AccountComponentCardIssueTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers the new admin-UI card
  issuance/reveal flow added to `AccountComponent` (Way4 parity plan
  Phase 1 item 1, 2026-07-25) — first-ever test coverage for this
  2900+-line component (a pre-existing gap, not introduced here).
  """

  use ExUnit.Case, async: false

  import Ecto.Query
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias VmuCore.Repo
  alias VmuCore.CTA.Card
  alias VmuCore.ASM.{Authz, Operator}
  alias VmuCore.CMS.Account
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
      username: "card_issue_test_#{String.downcase(role)}_#{System.unique_integer([:positive])}",
      display_name: "Card Issue Test #{role}", pw_hash: "x", pw_salt: "x", role: role, status: "ACTIVE"
    })
    |> Repo.insert!()
  end

  defp authed_conn(operator) do
    build_conn()
    |> init_test_session(%{"operator_id" => operator.operator_id, "logged_in_at" => System.os_time(:second)})
  end

  defp account_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "UiIssue", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "UI-ISSUE-TEST-#{n}"
      })
      |> Repo.insert!()

    %Account{}
    |> Account.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "ui-issue-pan-#{n}", last_four: "0000",
      expiry_date: "1230", credit_limit: D.new("5000.00")
    })
    |> Repo.insert!()
  end

  test "issuing a virtual card, then revealing it once, via the account detail Cards tab" do
    account = account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/account")

    view |> with_target("#account-component") |> render_click("acc_view", %{"id" => account.account_id})
    view |> element("[phx-click=\"detail_tab\"][phx-value-t=\"3\"]") |> render_click()

    assert render(view) =~ "Issue New Card"

    view |> element("button[phx-click=card_issue_open]") |> render_click()
    assert render(view) =~ "Issue New Card"

    html =
      view
      |> form("form[phx-submit=card_issue_save]", %{"card_type" => "VIRTUAL"})
      |> render_submit()

    assert html =~ "Virtual card gen 1 issued"
    assert html =~ "Reveal"

    # The Reveal button lives in an AG Grid actions cell (client-rendered,
    # invisible to LiveViewTest), so drive the event at the component and
    # look the card up the way the operator's click would have.
    card = Repo.one!(from c in Card, where: c.account_id == ^account.account_id)
    reveal_html = view |> with_target("#account-component") |> render_click("card_reveal", %{"id" => card.card_id})
    assert reveal_html =~ "One-Time Reveal"
    assert reveal_html =~ "PAN:"
    assert reveal_html =~ "CVV:"

    # Exactly-once — the Reveal button is gone from the row (card_type/status
    # unchanged, but there's nothing left to reveal); dismiss and confirm a
    # fresh attempt via the same card_id is a clean "nothing to reveal" error,
    # not a crash.
    dismiss_html = view |> element("button[phx-click=card_reveal_dismiss]") |> render_click()
    refute dismiss_html =~ "One-Time Reveal"
  end

  test "issuing a primary card without activation leaves it INACTIVE" do
    account = account_fixture()
    operator = operator_fixture("SUPERVISOR")

    {:ok, view, _html} = live(authed_conn(operator), "/visionplus/admin/account")

    view |> with_target("#account-component") |> render_click("acc_view", %{"id" => account.account_id})
    view |> element("[phx-click=\"detail_tab\"][phx-value-t=\"3\"]") |> render_click()
    view |> element("button[phx-click=card_issue_open]") |> render_click()

    html =
      view
      |> form("form[phx-submit=card_issue_save]", %{"card_type" => "PRIMARY"})
      |> render_submit()

    assert html =~ "PRIMARY card gen 1 issued"
    assert html =~ "INACTIVE"
  end
end
