defmodule VmuCoreWeb.Api.V1.Customer.NtsControllerTest do
  @moduledoc """
  Real Postgres via Sandbox + real Phoenix.ConnTest HTTP pipeline,
  `Req.Test` for the MDES HTTP boundary. NTS Phase F2 (2026-08-02), Case
  1 — Push to Merchant. Skipped if the real MDES key/cert aren't present,
  same convention as `PushProvisioningSessionsTest`.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.ASM.ServiceAccounts
  alias VmuCore.CAM.CustomerSession
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.CardLifecycle
  alias VmuCore.NTS.MastercardMdesClient
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  @endpoint VmuCoreWeb.Endpoint
  @cert_path "docs/wallet/mdes-token-connect-clientenc1785255654516-sandbox-client-encryption-key.pem"
  @private_key_path "docs/nts/myrsa.key"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    if File.exists?(@cert_path) and File.exists?(@private_key_path) do
      Application.put_env(:vmu_core, :mdes,
        consumer_key: "test-consumer-key", private_key_path: @private_key_path,
        cert_path: @cert_path, base_url: "https://mdes.test", google_pay_token_requestor_id: nil
      )
      Application.put_env(:vmu_core, :nts, callback_base_url: "https://issuer.test", kosa_app_base_url: "https://kosa.test")

      on_exit(fn ->
        Application.put_env(:vmu_core, :mdes, [])
        Application.put_env(:vmu_core, :nts, [])
      end)

      {:ok, conn: build_conn()}
    else
      {:skip, "real MDES cert/private key not present on this machine"}
    end
  end

  defp card_and_customer_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541236", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Nts", last_name: "CtrlTest#{n}", id_type: "PASSPORT", id_number: "NTSC-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "nts-ctrl-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "NTS CTRL#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    {card, customer}
  end

  defp app_token do
    n = System.unique_integer([:positive])
    {:ok, _account, raw_token} = ServiceAccounts.create(%{"name" => "nts-api-test-#{n}", "scopes" => ["nts:customer"]})
    raw_token
  end

  defp authed(conn, app_token, customer) do
    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer #{app_token}")
    |> Plug.Conn.put_req_header("x-customer-token", CustomerSession.issue(customer))
  end

  test "GET eligible_token_requestors filters by type and returns 200", %{conn: conn} do
    {card, customer} = card_and_customer_fixture()
    token = app_token()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{
        "responseId" => "r1",
        "tokenRequestors" => [
          %{"tokenRequestorId" => "1", "name" => "A", "consumerFacingEntityName" => "A", "tokenRequestorType" => "MERCHANT"},
          %{"tokenRequestorId" => "2", "name" => "B", "consumerFacingEntityName" => "B", "tokenRequestorType" => "WALLET"}
        ]
      })
    end)

    resp =
      conn
      |> authed(token, customer)
      |> get("/api/v1/customer/nts/eligible_token_requestors?card_id=#{card.card_id}&type=MERCHANT")
      |> json_response(200)

    assert [%{"tokenRequestorId" => "1"}] = resp["token_requestors"]
  end

  test "eligible_token_requestors returns 403 for a card that isn't the caller's", %{conn: conn} do
    {card, _owner} = card_and_customer_fixture()
    {_other_card, someone_else} = card_and_customer_fixture()
    token = app_token()

    resp =
      conn
      |> authed(token, someone_else)
      |> get("/api/v1/customer/nts/eligible_token_requestors?card_id=#{card.card_id}")
      |> json_response(403)

    assert resp["error"]["code"] == "forbidden"
  end

  test "POST push_sessions creates a session and returns a redirect_url", %{conn: conn} do
    {card, customer} = card_and_customer_fixture()
    token = app_token()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-ctrl-receipt"}],
        "availablePushMethods" => [%{"type" => "WEB", "uri" => "https://merchant.test/push"}]
      })
    end)

    resp =
      conn
      |> authed(token, customer)
      |> post("/api/v1/customer/nts/push_sessions", %{
        "card_id" => card.card_id, "token_requestor_id" => "50123456789",
        "pan" => "5412360000000123", "expiry_month" => "12", "expiry_year" => "30"
      })
      |> json_response(201)

    assert resp["status"] == "PENDING"
    assert resp["redirect_url"] =~ "receipt=MCC-ctrl-receipt"
  end

  test "POST push_sessions with someone else's card returns 403", %{conn: conn} do
    {card, _owner} = card_and_customer_fixture()
    {_other_card, someone_else} = card_and_customer_fixture()
    token = app_token()

    resp =
      conn
      |> authed(token, someone_else)
      |> post("/api/v1/customer/nts/push_sessions", %{
        "card_id" => card.card_id, "token_requestor_id" => "50123456789",
        "pan" => "5412360000000123", "expiry_month" => "12", "expiry_year" => "30"
      })
      |> json_response(403)

    assert resp["error"]["code"] == "forbidden"
  end

  test "no X-Customer-Token header returns 401", %{conn: conn} do
    token = app_token()

    resp =
      conn
      |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
      |> get("/api/v1/customer/nts/eligible_token_requestors?card_id=#{Ecto.UUID.generate()}")
      |> json_response(401)

    assert resp["error"]["code"] == "unauthorized"
  end
end
