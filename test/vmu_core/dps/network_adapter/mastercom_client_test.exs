defmodule VmuCore.DPS.NetworkAdapter.MastercomClientTest do
  @moduledoc """
  No mocking of the signing logic itself — a real throwaway RSA keypair is
  generated per test (`:public_key.generate_key/1`, written to a temp PEM
  file, loaded back through `MastercomClient`'s own `load_private_key/1`),
  and the resulting `Authorization` header's `oauth_signature` is verified
  with `:public_key.verify/4` against that same keypair's public half —
  proving the OAuth 1.0a + RSA-SHA256 + oauth_body_hash signing pipeline is
  internally correct, not just "doesn't crash." HTTP itself is routed
  through `Req.Test` (`config/test.exs`'s `:mastercom_http_plug`), same
  pattern as `ASM.OidcClient`'s tests. Re-ported 2026-07-29 from
  `Avenza/apps/vmu_dps` (DPS-P5) — this test file is new, the client
  and adapter existed there without one.
  """

  use ExUnit.Case, async: false

  require Record
  Record.defrecord(:rsa_private_key, :RSAPrivateKey, Record.extract(:RSAPrivateKey, from_lib: "public_key/include/public_key.hrl"))
  Record.defrecord(:rsa_public_key, :RSAPublicKey, Record.extract(:RSAPublicKey, from_lib: "public_key/include/public_key.hrl"))

  alias VmuCore.DPS.NetworkAdapter.MastercomClient

  setup do
    on_exit(fn -> Application.put_env(:vmu_core, :mastercom, []) end)
    :ok
  end

  defp write_keypair_and_configure(consumer_key \\ "test-consumer-key") do
    private_key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, private_key)
    pem = :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])

    path = Path.join(System.tmp_dir!(), "mastercom_test_key_#{System.unique_integer([:positive])}.pem")
    File.write!(path, pem)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:vmu_core, :mastercom,
      consumer_key: consumer_key, private_key_path: path, base_url: "https://mastercom.test"
    )

    private_key
  end

  defp public_key_from(private_key) do
    rsa_public_key(
      modulus: rsa_private_key(private_key, :modulus),
      publicExponent: rsa_private_key(private_key, :publicExponent)
    )
  end

  test "with no config at all, fails closed on the private key check (evaluated first)" do
    Application.put_env(:vmu_core, :mastercom, [])
    assert {:error, :missing_private_key} = MastercomClient.request(:post, "/claims", %{})
  end

  test "with a private key but no consumer_key, fails closed with :missing_consumer_key" do
    private_key = :public_key.generate_key({:rsa, 2048, 65537})
    der = :public_key.der_encode(:RSAPrivateKey, private_key)
    pem = :public_key.pem_encode([{:RSAPrivateKey, der, :not_encrypted}])
    path = Path.join(System.tmp_dir!(), "mastercom_test_key_#{System.unique_integer([:positive])}.pem")
    File.write!(path, pem)
    on_exit(fn -> File.rm(path) end)

    Application.put_env(:vmu_core, :mastercom, private_key_path: path, base_url: "https://mastercom.test")
    assert {:error, :missing_consumer_key} = MastercomClient.request(:post, "/claims", %{})
  end

  test "a real request is signed with a genuinely valid RSA-SHA256 OAuth 1.0a signature" do
    private_key = write_keypair_and_configure("real-consumer-key")
    public_key = public_key_from(private_key)
    test_pid = self()

    Req.Test.stub(MastercomClient, fn conn ->
      test_pid |> send({:captured_conn, conn})
      Req.Test.json(conn, %{"claimId" => "CLM-1"})
    end)

    assert {:ok, %{"claimId" => "CLM-1"}} =
             MastercomClient.request(:post, "/claims", %{"disputedAmount" => "100.00"})

    assert_receive {:captured_conn, conn}
    [auth_header] = Plug.Conn.get_req_header(conn, "authorization")
    assert String.starts_with?(auth_header, "OAuth ")

    params = parse_oauth_header(auth_header)
    assert params["oauth_consumer_key"] == "real-consumer-key"
    assert params["oauth_signature_method"] == "RSA-SHA256"

    body_json = Jason.encode!(%{"disputedAmount" => "100.00"})
    assert params["oauth_body_hash"] == :crypto.hash(:sha256, body_json) |> Base.encode64()

    base_string = signature_base_string("POST", "https://mastercom.test/claims", params)
    signature = Base.decode64!(params["oauth_signature"])

    assert :public_key.verify(base_string, :sha256, signature, public_key)
  end

  test "an HTTP error status is surfaced as {:error, {:http_error, status, body}}" do
    write_keypair_and_configure()

    Req.Test.stub(MastercomClient, fn conn ->
      conn |> Plug.Conn.put_status(422) |> Req.Test.json(%{"error" => "invalid claim"})
    end)

    assert {:error, {:http_error, 422, %{"error" => "invalid claim"}}} =
             MastercomClient.request(:post, "/claims", %{})
  end

  # ---------------------------------------------------------------------------
  # Local re-implementation of the client's own base-string construction, to
  # verify the signature independently rather than trusting the same code
  # that produced it.
  # ---------------------------------------------------------------------------

  defp parse_oauth_header("OAuth " <> rest) do
    rest
    |> String.split(", ")
    |> Map.new(fn pair ->
      [k, v] = String.split(pair, "=", parts: 2)
      {k, v |> String.trim("\"") |> URI.decode()}
    end)
  end

  defp signature_base_string(method, url, params) do
    oauth_params = Map.take(params, ~w[oauth_consumer_key oauth_nonce oauth_signature_method oauth_timestamp oauth_version oauth_body_hash])

    normalized =
      oauth_params
      |> Enum.map(fn {k, v} -> "#{percent_encode(k)}=#{percent_encode(v)}" end)
      |> Enum.sort()
      |> Enum.join("&")

    [method, percent_encode(url), percent_encode(normalized)] |> Enum.join("&")
  end

  defp percent_encode(value) do
    value |> to_string() |> URI.encode(&(&1 in ?A..?Z or &1 in ?a..?z or &1 in ?0..?9 or &1 in [?-, ?., ?_, ?~]))
  end
end
