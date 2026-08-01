defmodule VmuCore.NTS.MastercardPayloadEncryptionTest do
  @moduledoc """
  Two things are verified separately, deliberately not conflated:

  1. **Encryption against the real MDES cert** (`docs/wallet/
     mdes-token-connect-clientenc*.pem`) succeeds and produces
     correctly-shaped output. This is as far as this repo can ever verify
     end-to-end — the cert's matching *private* key is held by Mastercard,
     not us, so nothing on this machine can decrypt data encrypted for it
     (an earlier version of this test tried to decrypt using `docs/nts/
     myrsa.key`, which is a *different, unrelated* keypair used only for
     OAuth1.0a request signing — that decrypt attempt correctly failed
     with a real OpenSSL error, not a bug in the encryption code, a
     design mistake in the test caught before it shipped).
  2. **The scheme itself is cryptographically correct**, proven with a
     genuine round-trip against a throwaway self-signed certificate
     generated fresh per test run (`openssl`, deleted after) — encrypt
     with its public key, decrypt with its matching private key, confirm
     the exact original plaintext comes back.

  NTS Phase B (2026-07-31). Real-cert tests skip if the real MDES cert
  isn't present on this machine; the throwaway-cert round-trip test
  needs only `openssl` on PATH, so it runs everywhere.
  """

  use ExUnit.Case, async: false

  require Record
  Record.defrecord(:private_key_info, :PrivateKeyInfo, Record.extract(:PrivateKeyInfo, from_lib: "public_key/include/public_key.hrl"))

  alias VmuCore.NTS.MastercardPayloadEncryption

  @real_cert_path "docs/wallet/mdes-token-connect-clientenc1785255654516-sandbox-client-encryption-key.pem"

  # Only ever inspects the record tag (element 0) — never pattern-matches
  # the full tuple shape. Two earlier incidents this session came from a
  # hand-counted positional pattern with the wrong field count, which
  # crashed and dumped raw key material into the error output.
  defp load_private_key(path) do
    [entry | _] = path |> File.read!() |> :public_key.pem_decode()
    decoded = :public_key.pem_entry_decode(entry)

    case elem(decoded, 0) do
      :PrivateKeyInfo -> :public_key.der_decode(:RSAPrivateKey, private_key_info(decoded, :privateKey))
      :RSAPrivateKey -> decoded
    end
  end

  defp decrypt(%{
         "encryptedData" => encrypted_data, "encryptedKey" => encrypted_key_hex,
         "iv" => iv_hex, "algorithmCipherMode" => "CBC"
       }, private_key_path) do
    private_key = load_private_key(private_key_path)

    encrypted_key = Base.decode16!(encrypted_key_hex, case: :mixed)
    aes_key = :public_key.decrypt_private(encrypted_key, private_key, rsa_padding: :rsa_pkcs1_oaep_padding, rsa_oaep_md: :sha256)

    iv = Base.decode16!(iv_hex, case: :mixed)
    ciphertext = Base.decode64!(encrypted_data)

    padded = :crypto.crypto_one_time(:aes_128_cbc, aes_key, iv, ciphertext, false)
    pad_len = :binary.last(padded)
    :binary.part(padded, 0, byte_size(padded) - pad_len)
  end

  defp throwaway_cert_and_key! do
    n = System.unique_integer([:positive])
    key_path = Path.join(System.tmp_dir!(), "mdes_test_throwaway_key_#{n}.pem")
    cert_path = Path.join(System.tmp_dir!(), "mdes_test_throwaway_cert_#{n}.pem")

    {_, 0} =
      System.cmd("openssl", [
        "req", "-x509", "-newkey", "rsa:2048", "-keyout", key_path, "-out", cert_path,
        "-days", "1", "-nodes", "-subj", "/CN=vmu_core_test"
      ], stderr_to_stdout: true)

    {key_path, cert_path}
  end

  describe "against the real MDES certificate" do
    setup do
      if File.exists?(@real_cert_path), do: :ok, else: {:skip, "real MDES cert not present on this machine"}
    end

    test "encrypt/2 succeeds and produces correctly-shaped output" do
      plaintext = %{"cardAccountData" => %{"accountNumber" => "5412340000000001", "expiryMonth" => "12", "expiryYear" => "30"}}

      assert {:ok, encrypted} = MastercardPayloadEncryption.encrypt(plaintext, @real_cert_path)

      assert %{
               "encryptedData" => data, "publicKeyFingerprint" => fp, "encryptedKey" => key,
               "oaepHashingAlgorithm" => "SHA256", "iv" => iv, "algorithmCipherMode" => "CBC"
             } = encrypted

      assert String.length(fp) == 40
      assert String.length(iv) == 32
      assert byte_size(Base.decode16!(key, case: :mixed)) == 256
      assert byte_size(Base.decode64!(data)) > 0
    end

    test "each call uses a fresh AES key and IV — two encryptions of the same plaintext never match" do
      plaintext = %{"a" => "b"}

      {:ok, first} = MastercardPayloadEncryption.encrypt(plaintext, @real_cert_path)
      {:ok, second} = MastercardPayloadEncryption.encrypt(plaintext, @real_cert_path)

      refute first["encryptedData"] == second["encryptedData"]
      refute first["iv"] == second["iv"]
    end
  end

  describe "cryptographic correctness (throwaway self-signed cert, runs everywhere)" do
    test "encrypt/2 round-trips back to the exact original plaintext" do
      {key_path, cert_path} = throwaway_cert_and_key!()
      on_exit(fn -> File.rm(key_path); File.rm(cert_path) end)

      plaintext = %{"cardAccountData" => %{"accountNumber" => "5412340000000001", "expiryMonth" => "12", "expiryYear" => "30"}}

      assert {:ok, encrypted} = MastercardPayloadEncryption.encrypt(plaintext, cert_path)
      assert Jason.decode!(decrypt(encrypted, key_path)) == plaintext
    end

    test "round-trips an array payload too (pushMultipleAccounts' real shape)" do
      {key_path, cert_path} = throwaway_cert_and_key!()
      on_exit(fn -> File.rm(key_path); File.rm(cert_path) end)

      plaintext = [%{"pushAccountId" => "CA-1", "fundingAccountData" => %{"cardAccountData" => %{"accountNumber" => "5412340000000002"}}}]

      assert {:ok, encrypted} = MastercardPayloadEncryption.encrypt(plaintext, cert_path)
      assert Jason.decode!(decrypt(encrypted, key_path)) == plaintext
    end
  end

  test "an unreadable cert path fails cleanly instead of raising" do
    assert {:error, :enoent} = MastercardPayloadEncryption.encrypt(%{"a" => "b"}, "docs/nts/does_not_exist.pem")
  end
end
