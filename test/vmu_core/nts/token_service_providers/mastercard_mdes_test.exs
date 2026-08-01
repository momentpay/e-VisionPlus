defmodule VmuCore.NTS.TokenServiceProviders.MastercardMdesTest do
  @moduledoc """
  Real Postgres via Sandbox for BIN resolution, `Req.Test` for the true
  external-HTTP boundary. NTS Phase B (2026-07-31). Skipped if the real
  MDES key/cert files aren't present on this machine.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  alias VmuCore.CTA.{Card, CardLifecycle}
  alias VmuCore.NTS.MastercardMdesClient
  alias VmuCore.NTS.TokenServiceProviders.MastercardMdes
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

      on_exit(fn -> Application.put_env(:vmu_core, :mdes, []) end)
      :ok
    else
      {:skip, "real MDES cert/private key not present on this machine"}
    end
  end

  defp card_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "541234", description: "test", card_validity_years: 4}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Mdes", last_name: "Test#{n}", id_type: "PASSPORT", id_number: "MDES-#{n}"})
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "mdes-existing-pan-#{n}", last_four: "0000",
        expiry_date: "1230", credit_limit: D.new("5000.00"), emboss_name: "MDES TEST#{n}"
      })
      |> Repo.insert!()

    {:ok, card} = CardLifecycle.issue_new(account, activate: true)
    card
  end

  defp device_info do
    %{"pan" => "5412340000000123", "expiry_month" => "12", "expiry_year" => "30"}
  end

  test "provision_token/3 pushes the account to Google Pay and returns PUSHED with no dpan yet" do
    card = card_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      case conn.request_path do
        "/connect/1/0/getEligibleTokenRequestors" ->
          Req.Test.json(conn, %{
            "responseId" => "r1",
            "tokenRequestors" => [
              %{"tokenRequestorId" => "50123456789", "name" => "Google LLC",
                "consumerFacingEntityName" => "Google Pay", "tokenRequestorType" => "WALLET"}
            ]
          })

        "/connect/1/0/pushMultipleAccounts" ->
          Req.Test.json(conn, %{
            "responseId" => "r2",
            "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-real-receipt"}]
          })
      end
    end)

    assert {:ok, %{token_reference_id: "MCC-real-receipt", dpan: nil, status: "PUSHED"}} =
             MastercardMdes.provision_token(card, device_info(), "GOOGLE_PAY")
  end

  test "provision_token/3 fails cleanly when Google Pay isn't eligible for this BIN" do
    card = card_fixture()

    Req.Test.stub(MastercardMdesClient, fn conn ->
      Req.Test.json(conn, %{"responseId" => "r1", "tokenRequestors" => []})
    end)

    assert {:error, :google_pay_not_eligible_for_this_bin} =
             MastercardMdes.provision_token(card, device_info(), "GOOGLE_PAY")
  end

  test "provision_token/3 fails cleanly when the caller doesn't supply pan/expiry" do
    card = card_fixture()
    assert {:error, {:missing_field, "pan"}} = MastercardMdes.provision_token(card, %{}, "GOOGLE_PAY")
  end

  test "provision_token/3 rejects unsupported wallets outright" do
    card = card_fixture()
    assert {:error, {:unsupported_wallet, "APPLE_PAY"}} = MastercardMdes.provision_token(card, device_info(), "APPLE_PAY")
  end

  test "a configured google_pay_token_requestor_id skips discovery entirely" do
    card = card_fixture()
    Application.put_env(:vmu_core, :mdes, Keyword.put(Application.get_env(:vmu_core, :mdes), :google_pay_token_requestor_id, "50199999999"))

    Req.Test.stub(MastercardMdesClient, fn conn ->
      assert conn.request_path == "/connect/1/0/pushMultipleAccounts"
      assert conn.body_params["tokenRequestorId"] == "50199999999"
      Req.Test.json(conn, %{"responseId" => "r2", "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-x"}]})
    end)

    assert {:ok, %{status: "PUSHED"}} = MastercardMdes.provision_token(card, device_info(), "GOOGLE_PAY")
  end

  test "suspend/resume/delete are honestly not implemented (Token Connect has no lifecycle API in scope)" do
    assert {:error, :mdes_lifecycle_api_not_in_scope} = MastercardMdes.suspend_token(%VmuCore.NTS.Token{})
    assert {:error, :mdes_lifecycle_api_not_in_scope} = MastercardMdes.resume_token(%VmuCore.NTS.Token{})
    assert {:error, :mdes_lifecycle_api_not_in_scope} = MastercardMdes.delete_token(%VmuCore.NTS.Token{})
  end
end
