defmodule VmuCore.NTS.PushProvisioningSessionsTest do
  @moduledoc """
  Real Postgres via Sandbox for BIN resolution + session persistence,
  `Req.Test` for the true external-HTTP boundary. NTS Phase F2
  (2026-08-02), Case 1 — Push to Merchant. Skipped if the real MDES
  key/cert files aren't present, same convention as `MastercardMdesTest`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.CardLifecycle
  alias VmuCore.NTS.{MastercardMdesClient, PushProvisioningSessions, Token, Tokens}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

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

      :ok
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541235", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Push", last_name: "SessTest#{n}", id_type: "PASSPORT", id_number: "PUSHS-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "push-sess-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "PUSH SESS#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    {card, customer}
  end

  defp funding_account do
    %{"cardAccountData" => %{"accountNumber" => "5412350000000123", "expiryMonth" => "12", "expiryYear" => "30"}}
  end

  test "start_push/5 creates a PENDING token+session and returns a redirect URL with the receipt and callback appended" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      assert conn.body_params["requestIssuerInitiatedDigitizationData"] == false
      assert conn.body_params["signatureData"]["callbackURL"] =~ "/nts/callback/"

      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-merchant-receipt"}],
        "availablePushMethods" => [%{"type" => "WEB", "uri" => "https://merchant.test/push"}]
      })
    end)

    assert {:ok, session, redirect_url} =
             PushProvisioningSessions.start_push(card.card_id, customer.customer_id, "50123456789", funding_account())

    assert session.status == "PENDING"
    assert session.push_account_receipt == "MCC-merchant-receipt"
    assert redirect_url =~ "https://merchant.test/push?"
    assert redirect_url =~ "receipt=MCC-merchant-receipt"
    assert redirect_url =~ "callback="

    token = Repo.get!(Token, session.token_id)
    assert token.status == "PENDING"
    assert token.wallet == "TOKEN_REQUESTOR"
  end

  test "start_push/5 fails cleanly and deletes the token when MDES returns no receipt" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{"responseId" => "r1", "pushAccountReceipts" => []})
    end)

    assert {:error, :no_receipt_returned} =
             PushProvisioningSessions.start_push(card.card_id, customer.customer_id, "50123456789", funding_account())
  end

  test "complete/2 with a success result activates the token" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-r"}],
        "availablePushMethods" => [%{"type" => "WEB", "uri" => "https://merchant.test/push"}]
      })
    end)

    {:ok, session, _url} = PushProvisioningSessions.start_push(card.card_id, customer.customer_id, "50123456789", funding_account())

    assert {:ok, completed} = PushProvisioningSessions.complete(session.session_id, %{"result" => "SUCCESS"})
    assert completed.status == "COMPLETED"
    assert Tokens.get(session.token_id).status == "ACTIVE"
  end

  test "complete/2 with a REQUIRE_ADDITIONAL_AUTHENTICATION result lands in AUTH_REQUIRED" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-r"}],
        "availablePushMethods" => [%{"type" => "WEB", "uri" => "https://merchant.test/push"}]
      })
    end)

    {:ok, session, _url} = PushProvisioningSessions.start_push(card.card_id, customer.customer_id, "50123456789", funding_account())

    assert {:ok, completed} = PushProvisioningSessions.complete(session.session_id, %{"result" => "REQUIRE_ADDITIONAL_AUTHENTICATION"})
    assert completed.status == "AUTH_REQUIRED"
    assert completed.requires_authentication == true
    assert Tokens.get(session.token_id).status == "PENDING"
  end

  test "complete/2 with an unknown session id returns :not_found" do
    assert {:error, :not_found} = PushProvisioningSessions.complete(Ecto.UUID.generate(), %{})
  end

  test "list_eligible_token_requestors/2 filters by tokenRequestorType" do
    {card, _customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{
        "responseId" => "r1",
        "tokenRequestors" => [
          %{"tokenRequestorId" => "1", "name" => "A", "consumerFacingEntityName" => "A", "tokenRequestorType" => "MERCHANT"},
          %{"tokenRequestorId" => "2", "name" => "B", "consumerFacingEntityName" => "B", "tokenRequestorType" => "WALLET"}
        ]
      })
    end)

    assert {:ok, [%{"tokenRequestorId" => "1"}]} = PushProvisioningSessions.list_eligible_token_requestors(card.card_id, "MERCHANT")
  end

  test "start_proprietary_push/4 (Case 4) pushes with requestIssuerInitiatedDigitizationData: true and no callback_url, returns the digitization data" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      assert conn.body_params["requestIssuerInitiatedDigitizationData"] == true
      refute Map.has_key?(conn.body_params, "signatureData")

      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-prop"}],
        "issuerInitiatedDigitizationData" => %{"opaque" => "blob"}
      })
    end)

    assert {:ok, session, digitization_data} =
             PushProvisioningSessions.start_proprietary_push(card.card_id, customer.customer_id, "50123456789", funding_account())

    assert session.status == "COMPLETED"
    assert digitization_data == %{"opaque" => "blob"}
    assert Tokens.get(session.token_id).status == "PUSHED"
  end

  test "start_proprietary_push/4 fails cleanly and deletes the token when MDES returns no receipt" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{"responseId" => "r1", "pushAccountReceipts" => []})
    end)

    assert {:error, :no_receipt_returned} =
             PushProvisioningSessions.start_proprietary_push(card.card_id, customer.customer_id, "50123456789", funding_account())
  end

  test "start_pull/5 (Case 5) sends tokenRequestorSessionId, not callbackURL, and returns the wallet_callback_url with the receipt appended" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      assert conn.body_params["requestIssuerInitiatedDigitizationData"] == false
      assert conn.body_params["signatureData"]["tokenRequestorSessionId"] == "wallet-sess-123"
      refute Map.has_key?(conn.body_params["signatureData"], "callbackURL")

      Req.Test.json(conn, %{
        "responseId" => "r1",
        "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-pull"}],
        "signature" => "jws-signature-value"
      })
    end)

    assert {:ok, session, redirect_url} =
             PushProvisioningSessions.start_pull(
               card.card_id, customer.customer_id, "50123456789", funding_account(),
               wallet_session_id: "wallet-sess-123", wallet_callback_url: "https://googlepay.test/callback"
             )

    assert session.status == "COMPLETED"
    assert session.direction == "pull"
    assert session.wallet_session_id == "wallet-sess-123"
    assert redirect_url == "https://googlepay.test/callback?receipt=MCC-pull&signature=jws-signature-value"
    assert Tokens.get(session.token_id).status == "PUSHED"
  end

  test "start_pull/5 fails cleanly and deletes the token when MDES returns no receipt" do
    {card, customer} = card_and_customer_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{"responseId" => "r1", "pushAccountReceipts" => []})
    end)

    assert {:error, :no_receipt_returned} =
             PushProvisioningSessions.start_pull(
               card.card_id, customer.customer_id, "50123456789", funding_account(),
               wallet_session_id: "wallet-sess-999", wallet_callback_url: "https://googlepay.test/callback"
             )
  end

  test "card_belongs_to_customer?/2 is true for the owning customer and false otherwise" do
    {card, customer} = card_and_customer_fixture()
    {_other_card, other_customer} = card_and_customer_fixture()

    assert PushProvisioningSessions.card_belongs_to_customer?(card.card_id, customer.customer_id)
    refute PushProvisioningSessions.card_belongs_to_customer?(card.card_id, other_customer.customer_id)
  end
end
