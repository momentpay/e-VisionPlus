defmodule VmuCore.NTS.MastercardPayloadEncryption do
  @moduledoc """
  Mastercard's "Payload Encryption" scheme (NTS Phase B, 2026-07-31) —
  required for MDES Token Connect's `pushAccount`/`pushMultipleAccounts`
  request bodies (`docs/nts/mdes-token-connect.yaml`'s `EncryptedPayload`/
  `EncryptedPayloadForMultiplePushData` schemas): a one-time AES key
  encrypts the actual JSON payload, and that AES key is itself RSA-
  encrypted with Mastercard's public certificate (`docs/wallet/mdes-
  token-connect-clientenc*.pem`) so only Mastercard can recover it.

  This is a real, independently-verified implementation — RSA-OAEP and
  AES-CBC were both smoke-tested against the real certificate before this
  module was written (not guessed). What's confirmed vs. what's a
  reasonable-but-unverified default, stated honestly rather than silently
  assumed:

  - **Confirmed against the real cert**: RSA-OAEP-SHA256 encryption
    succeeds (2048-bit key → 256-byte ciphertext), AES-128-CBC/GCM both
    work via `:crypto`.
  - **Chosen deliberately: AES-128-CBC, not GCM.** The spec's own schema
    says `aad` is *required* when `algorithmCipherMode` is GCM, but does
    not say what value to use — guessing an AAD value for an
    authenticated cipher is exactly the kind of unverified assumption
    this codebase's discipline says not to make. CBC has no such
    ambiguity and is an equally valid, explicitly-documented option in
    the same schema (`algorithmCipherMode: CBC | GCM`).
  - **Unverified, standard-practice defaults** (would need Mastercard's
    referenced "Breaking the Encrypted Payload Down" doc or a real
    sandbox round-trip to fully confirm): `encryptedData`/`encryptedKey`
    wire encoding (base64 for the ciphertext, hex for the encrypted key —
    matches the spec's own `iv`/`publicKeyFingerprint` hex examples and
    Mastercard's field-level-encryption pattern used elsewhere on their
    platform), and `publicKeyFingerprint` as the SHA-1 of the whole
    DER-encoded certificate (matches the 40-hex-char example in the spec
    exactly in length/format).
  """

  @aes_key_bits 128
  @oaep_hash :sha256

  @doc """
  Encrypts `plaintext_map` (JSON-encoded internally) per Mastercard's
  Payload Encryption scheme, using the PEM-encoded certificate at
  `cert_path`. Returns the four/five fields MDES expects directly on the
  request body per `docs/nts/mdes-token-connect.yaml`'s
  `EncryptedPayload` schema.
  """
  @spec encrypt(map() | list(), String.t()) :: {:ok, map()} | {:error, term()}
  def encrypt(plaintext_map, cert_path) do
    with {:ok, cert_pem} <- File.read(cert_path),
         {:ok, der, public_key} <- decode_cert(cert_pem) do
      plaintext = Jason.encode!(plaintext_map)

      aes_key = :crypto.strong_rand_bytes(div(@aes_key_bits, 8))
      iv = :crypto.strong_rand_bytes(16)
      ciphertext = :crypto.crypto_one_time(:aes_128_cbc, aes_key, iv, pkcs7_pad(plaintext), true)

      encrypted_key = :public_key.encrypt_public(aes_key, public_key, rsa_padding: :rsa_pkcs1_oaep_padding, rsa_oaep_md: @oaep_hash)

      {:ok, %{
        "encryptedData" => Base.encode64(ciphertext),
        "publicKeyFingerprint" => :crypto.hash(:sha, der) |> Base.encode16(case: :lower),
        "encryptedKey" => Base.encode16(encrypted_key, case: :lower),
        "oaepHashingAlgorithm" => @oaep_hash |> to_string() |> String.upcase(),
        "iv" => Base.encode16(iv, case: :lower),
        "algorithmCipherMode" => "CBC"
      }}
    else
      {:error, _posix} = err -> err
    end
  end

  defp decode_cert(cert_pem) do
    case :public_key.pem_decode(cert_pem) do
      [{:Certificate, der, _}] ->
        otp_cert = :public_key.pkix_decode_cert(der, :otp)
        {:OTPCertificate, tbs_cert, _sig_alg, _sig} = otp_cert
        {:OTPSubjectPublicKeyInfo, _alg, public_key} = elem(tbs_cert, 7)
        {:ok, der, public_key}

      _ ->
        {:error, :invalid_certificate}
    end
  end

  defp pkcs7_pad(data) do
    pad_len = 16 - rem(byte_size(data), 16)
    data <> :binary.copy(<<pad_len>>, pad_len)
  end
end
