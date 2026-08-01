defmodule VmuCore.NTS.MastercardMdesClientTest do
  @moduledoc """
  Real Postgres not needed — this is a pure HTTP-signing test, same
  pattern as `MastercomClientTest`. No mocking of the signing logic;
  `Req.Test` fakes only the true external-HTTP boundary. NTS Phase B
  (2026-07-31).
  """

  use ExUnit.Case, async: false

  alias VmuCore.NTS.MastercardMdesClient

  setup do
    on_exit(fn -> Application.put_env(:vmu_core, :mdes, []) end)
    :ok
  end

  defp configure_with_real_key(overrides \\ %{}) do
    base = %{
      consumer_key: "test-consumer-key",
      private_key_path: "docs/nts/myrsa.key",
      cert_path: "docs/wallet/mdes-token-connect-clientenc1785255654516-sandbox-client-encryption-key.pem",
      base_url: "https://mdes.test"
    }

    Application.put_env(:vmu_core, :mdes, Map.merge(base, overrides) |> Map.to_list())
  end

  test "with no config at all, fails closed on the private key check" do
    Application.put_env(:vmu_core, :mdes, [])
    assert {:error, :missing_private_key} = MastercardMdesClient.request(:post, "/connect/1/0/getEligibleTokenRequestors", %{})
  end

  @tag :real_credentials
  test "a request is signed with the real key and reaches the stubbed endpoint" do
    if File.exists?("docs/nts/myrsa.key") do
      configure_with_real_key()

      Req.Test.stub(MastercardMdesClient, fn conn ->
        [auth] = Plug.Conn.get_req_header(conn, "authorization")
        assert String.starts_with?(auth, "OAuth ")
        Req.Test.json(conn, %{"responseId" => "1", "tokenRequestors" => []})
      end)

      assert {:ok, %{"responseId" => "1"}} =
               MastercardMdesClient.get_eligible_token_requestors(["5412340000"], "req-1")
    end
  end

  test "get_eligible_token_requestors/2 sends the real endpoint shape" do
    if File.exists?("docs/nts/myrsa.key") do
      configure_with_real_key()
      test_pid = self()

      Req.Test.stub(MastercardMdesClient, fn conn ->
        send(test_pid, {:captured, conn.request_path, conn.body_params})
        Req.Test.json(conn, %{"responseId" => "req-1", "tokenRequestors" => []})
      end)

      assert {:ok, _} = MastercardMdesClient.get_eligible_token_requestors(["5412340000"], "req-1")

      assert_receive {:captured, "/connect/1/0/getEligibleTokenRequestors", body}
      assert body["requestId"] == "req-1"
      assert body["accountRanges"] == ["5412340000"]
    end
  end

  test "push_multiple_accounts/4 encrypts the funding account, never sends it plaintext" do
    if File.exists?("docs/nts/myrsa.key") do
      configure_with_real_key()
      test_pid = self()

      Req.Test.stub(MastercardMdesClient, fn conn ->
        send(test_pid, {:captured, conn.body_params})
        Req.Test.json(conn, %{"responseId" => "req-2", "pushAccountReceipts" => [%{"pushAccountId" => "CA-1", "pushAccountReceipt" => "MCC-abc"}]})
      end)

      funding_account = %{"cardAccountData" => %{"accountNumber" => "5412340000000099", "expiryMonth" => "12", "expiryYear" => "30"}}

      assert {:ok, %{"pushAccountReceipts" => [%{"pushAccountReceipt" => "MCC-abc"}]}} =
               MastercardMdesClient.push_multiple_accounts("req-2", "50123456789", funding_account, "CA-1")

      assert_receive {:captured, body}
      refute inspect(body) =~ "5412340000000099"
      assert body["requestIssuerInitiatedDigitizationData"] == true
      assert get_in(body, ["pushFundingAccounts", "encryptedPayload", "algorithmCipherMode"]) == "CBC"
    end
  end
end
