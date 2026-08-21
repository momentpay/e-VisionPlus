defmodule VmuCoreWeb.NtsCallbackControllerTest do
  @moduledoc """
  Real Postgres via Sandbox + real Phoenix.ConnTest HTTP pipeline,
  `Req.Test` for the MDES HTTP boundary. NTS Phase F2 (2026-08-02) — the
  public GET /nts/callback/:session_id route a Token Requestor redirects
  the cardholder's browser back to.
  """

  use ExUnit.Case, async: false

  import Phoenix.ConnTest

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.CardLifecycle
  alias VmuCore.NTS.{MastercardMdesClient, PushProvisioningSessions, Tokens}
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

  defp session_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541237", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Nts", last_name: "CbTest#{n}", id_type: "PASSPORT", id_number: "NTSCB-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "nts-cb-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "NTS CB#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-cb"}],
        "availablePushMethods" => [%{"type" => "WEB", "uri" => "https://merchant.test/push"}]
      })
    end)

    funding_account = %{"cardAccountData" => %{"accountNumber" => "5412370000000123", "expiryMonth" => "12", "expiryYear" => "30"}}
    {:ok, session, _url} = PushProvisioningSessions.start_push(card.card_id, customer.customer_id, "50123456789", funding_account)
    session
  end

  test "GET /nts/callback/:session_id with a success result completes the session and redirects to Kosa", %{conn: conn} do
    session = session_fixture()

    conn = get(conn, "/nts/callback/#{session.session_id}?result=SUCCESS")

    assert conn.status == 302
    location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
    assert location =~ "https://kosa.test/nts/result"
    assert location =~ "status=COMPLETED"

    assert Tokens.get(session.token_id).status == "ACTIVE"
  end

  test "GET /nts/callback/:session_id with an unknown session redirects with UNKNOWN_SESSION", %{conn: conn} do
    conn = get(conn, "/nts/callback/#{Ecto.UUID.generate()}")

    assert conn.status == 302
    location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
    assert location =~ "status=UNKNOWN_SESSION"
  end

  test "GET /nts/callback/:session_id with a failure result marks the session FAILED, token stays PENDING", %{conn: conn} do
    session = session_fixture()

    conn = get(conn, "/nts/callback/#{session.session_id}?result=DECLINED")

    location = Plug.Conn.get_resp_header(conn, "location") |> List.first()
    assert location =~ "status=FAILED"
    assert Tokens.get(session.token_id).status == "PENDING"
  end
end
