defmodule VmuCoreWeb.Api.V1.Customer.CardsControllerTest do
  @moduledoc "Real Postgres via Sandbox + real Phoenix.ConnTest HTTP pipeline. NTS Phase F6 (2026-08-02)."

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccounts
  alias VmuCore.CAM.CustomerSession
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.Cards
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    {:ok, conn: build_conn()}
  end

  defp pan_token(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

  defp customer_with_card_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541239", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Cards", last_name: "CtrlTest#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
        pan_token: pan_token("cards-ctrl-#{n}"), last_four: "4242", expiry_date: "1230",
        credit_limit: D.new("1000.00"), emboss_name: "CARDS CTRL#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = Cards.issue(%{account_id: account.account_id, pan_token: pan_token("cards-ctrl-#{n}"), card_type: "PRIMARY", status: "ACTIVE", last_four: "4242"})
    {customer, card}
  end

  defp app_token do
    n = System.unique_integer([:positive])
    {:ok, _account, raw_token} = ServiceAccounts.create(%{"name" => "cards-api-test-#{n}", "scopes" => ["nts:customer"]})
    raw_token
  end

  test "GET /api/v1/customer/cards returns only the authenticated cardholder's cards", %{conn: conn} do
    {customer, card} = customer_with_card_fixture()
    {_other_customer, _other_card} = customer_with_card_fixture()
    token = app_token()

    resp =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> Plug.Conn.put_req_header("x-customer-token", CustomerSession.issue(customer))
      |> get("/api/v1/customer/cards")
      |> json_response(200)

    assert [%{"card_id" => card_id, "last_four" => "4242"}] = resp["cards"]
    assert card_id == card.card_id
  end
end
