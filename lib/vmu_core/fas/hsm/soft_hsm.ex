defmodule VmuCore.FAS.HSM.SoftHSM do
  @moduledoc """
  Software HSM for dev / UAT environments (FAS-P7 7B).

  Implements `VmuCore.FAS.HSM` behaviour using `:crypto` (OTP built-in).
  **NOT for production** — key material lives in application config, not in
  hardware secure storage.

  ## Configuration

      # config/dev.exs
      config :vmu_core, :soft_hsm,
        cvk:                Base.decode16!("0123456789ABCDEFFEDCBA9876543210"),  # 16-byte CVK
        arqc_verify_enabled: false,   # true = verify with test IMK; false = fail-open
        pin_verify_enabled:  true,    # false = skip PIN check (useful for integration tests)
        test_imk:           nil       # 16-byte ICC Master Key for test cards only

  ## CVV Algorithm

  Implements the Visa/MC 3DES CVV generation algorithm:
    1. Build 32 hex-char string: PAN (sans check digit) + YYMM + service_code
    2. Split into two 8-byte blocks; DES-ECB encrypt first block with CVK left half
    3. XOR result with second block; 3DES-ECB encrypt with full CVK
    4. Decimalize: extract digits first, then A-F → 0-5
    5. First 3 characters = CVV value

  ## ARQC Verification

  When `arqc_verify_enabled: false` (default in dev), all ARQCs are accepted
  with a debug log. Set to `true` only when a valid test ICC Master Key is
  configured for test card ranges — without matching key material, every real
  ARQC will fail verification.

  ## PIN Verification

  Decodes ISO 9564 Format-0 PIN block (XOR with PAN block), then compares
  to `cms_card_pins.pin_hash` using PBKDF2-SHA256. Try counter is incremented
  on each wrong PIN; the card is locked after `max_pin_tries` (from logo params,
  default 3). Try counter is reset on success.
  """

  @behaviour VmuCore.FAS.HSM
  require Logger
  import Bitwise
  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.CardPin

  # ---------------------------------------------------------------------------
  # CVV Verification (7D)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def verify_cvv(pan, expiry, service_code, cvv) do
    cvk = get_cvk()

    if is_nil(cvk) do
      Logger.debug("[SoftHSM] CVK not configured — CVV check skipped (dev mode)")
      :ok
    else
      expected = compute_cvv(pan, expiry, service_code, cvk)

      if cvv == expected do
        :ok
      else
        Logger.debug("[SoftHSM] CVV mismatch: expected=#{expected} received=#{cvv}")
        {:error, :cvv_mismatch}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # ARQC Verification (7G)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def verify_arqc(pan_token, atc, un, txn_data, arqc) do
    if arqc_verify_enabled?() do
      imk = get_imk()

      if is_nil(imk) do
        Logger.warning("[SoftHSM] ARQC verify enabled but IMK not configured — fail-open")
        :ok
      else
        session_key = derive_session_key(imk, atc)
        data        = build_arqc_data(pan_token, atc, un, txn_data)
        expected    = des3_cbc_mac(session_key, data)

        if expected == arqc do
          :ok
        else
          Logger.debug("[SoftHSM] ARQC mismatch for pan_token=#{String.slice(pan_token, 0, 8)}...")
          {:error, :arqc_mismatch}
        end
      end
    else
      Logger.debug("[SoftHSM] ARQC verify disabled — fail-open (dev)")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # ARPC Generation (7G)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def generate_arpc(arqc, arc, pan_token) do
    imk = get_imk()

    if is_nil(imk) do
      # Synthetic ARPC: XOR ARQC with ARC padded to 8 bytes (no real session key)
      arc_padded  = arc <> :binary.copy(<<0>>, 8 - byte_size(arc))
      arpc = :crypto.exor(arqc, arc_padded)
      {:ok, arpc}
    else
      # Real ARPC: Method 1 — XOR ARQC with ARC, encrypt with session key
      # (This would need the ATC; for now use the full ARQC as approximation)
      _ = pan_token  # suppress unused warning
      arc_padded  = arc <> :binary.copy(<<0>>, 8 - byte_size(arc))
      intermediate = :crypto.exor(arqc, arc_padded)
      cvk          = binary_part(imk, 0, 16)
      cvk_24       = cvk <> binary_part(cvk, 0, 8)
      arpc = :crypto.crypto_one_time(:des_ede3_ecb, cvk_24, intermediate, true)
      {:ok, arpc}
    end
  rescue
    e ->
      Logger.error("[SoftHSM] generate_arpc failed: #{Exception.message(e)}")
      {:error, :arpc_failed}
  end

  # ---------------------------------------------------------------------------
  # PIN Verification (7E)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def verify_pin(pin_block_hex, pan, pan_token) do
    unless pin_verify_enabled?() do
      Logger.debug("[SoftHSM] PIN verify disabled — skip (dev)")
      :ok
    else
      case decode_pin_block(pin_block_hex, pan) do
        {:ok, pin_digits} ->
          verify_pin_against_stored(pin_digits, pan_token)

        {:error, reason} ->
          Logger.warning("[SoftHSM] PIN block decode failed: #{reason}")
          {:error, :wrong_pin}
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Issuer Scripts (7H)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def build_issuer_scripts(_pan_token, commands) do
    # Build TLV-encoded issuer scripts for DE55 response
    # Tag 72 = issuer script template 2 (runs after Generate AC)
    # Tag 71 = issuer script template 1 (runs before Generate AC)
    # Script command format: <<CLA, INS, P1, P2, Lc, Data...>>
    scripts =
      Enum.flat_map(commands, fn
        :block_card ->
          # PUT DATA: set Application Lifecycle Status to "blocked" (0x07)
          cmd = <<0x84, 0xDA, 0x00, 0x97, 0x01, 0x07>>
          [build_tlv(0x72, cmd)]

        :reset_pin_tries ->
          # RESET RETRY COUNTER command (proprietary — varies by chip OS)
          cmd = <<0x84, 0x44, 0x00, 0x00, 0x00>>
          [build_tlv(0x71, cmd)]

        :update_params ->
          # PUT DATA: update CVM list (generic example)
          cmd = <<0x84, 0xDA, 0x00, 0x5F, 0x00>>
          [build_tlv(0x71, cmd)]

        unknown ->
          Logger.warning("[SoftHSM] Unknown script command: #{inspect(unknown)}")
          []
      end)

    {:ok, IO.iodata_to_binary(scripts)}
  end

  # ---------------------------------------------------------------------------
  # CVV algorithm internals
  # ---------------------------------------------------------------------------

  defp compute_cvv(pan, expiry, service_code, cvk) when byte_size(cvk) == 16 do
    pan_no_check = String.slice(pan, 0..-2//1)

    raw = (pan_no_check <> expiry <> service_code)
          |> String.replace(~r/[^0-9]/, "")

    # Pad or truncate to 32 hex digits (= 16 bytes raw, represented as digits)
    data_hex = String.pad_trailing(raw, 32, "0") |> String.slice(0, 32)

    block1 = hex_to_bytes!(data_hex, 0, 16)
    block2 = hex_to_bytes!(data_hex, 16, 16)

    cvk_a = binary_part(cvk, 0, 8)
    cvk_b = binary_part(cvk, 8, 8)

    # DES ECB encrypt block1 with left half of CVK
    e1 = :crypto.crypto_one_time(:des_ecb, cvk_a, block1, true)

    # XOR e1 with block2
    xor_result = :crypto.exor(e1, block2)

    # 3DES ECB encrypt with full CVK (2-key → K1|K2|K1)
    cvk_24 = cvk_a <> cvk_b <> cvk_a
    e2 = :crypto.crypto_one_time(:des_ede3_ecb, cvk_24, xor_result, true)

    # Decimalize: digits 0-9 first, then hex A-F → 0-5
    e2
    |> Base.encode16(case: :lower)
    |> decimalize()
    |> String.slice(0, 3)
  end

  defp compute_cvv(_, _, _, cvk) do
    Logger.error("[SoftHSM] CVK must be 16 bytes, got #{byte_size(cvk)}")
    "000"
  end

  # Decimalize step: take digit chars first, replace hex letters with 0-5
  defp decimalize(hex_str) do
    digits  = for c <- String.graphemes(hex_str), c =~ ~r/[0-9]/, do: c
    letters = for c <- String.graphemes(hex_str), c =~ ~r/[a-f]/,
                  do: Integer.to_string(String.to_integer(c, 16) - 10)
    (digits ++ letters) |> Enum.join()
  end

  # Convert a 16-char hex slice (at offset `offset`) to 8 bytes
  defp hex_to_bytes!(hex_str, offset, len) do
    hex_str |> String.slice(offset, len) |> Base.decode16!(case: :mixed)
  end

  # ---------------------------------------------------------------------------
  # ARQC internals
  # ---------------------------------------------------------------------------

  # Simplified Visa-style ARQC diversification:
  # Session Key = 3DES-ECB(IMK, ATC || FF FF || ATC_complement)
  defp derive_session_key(imk, atc) when byte_size(atc) == 2 do
    atc_comp = :crypto.exor(atc, <<0xFF, 0xFF>>)
    data_l = atc <> <<0xFF, 0xFF>> <> atc_comp <> <<0x00, 0x00>>
    data_r = atc <> <<0xFF, 0xFF>> <> atc_comp <> <<0x00, 0x01>>

    key_l = des3_ecb_encrypt(imk, data_l)
    key_r = des3_ecb_encrypt(imk, data_r)

    binary_part(key_l, 0, 8) <> binary_part(key_r, 0, 8)
  end

  defp build_arqc_data(_pan_token, atc, un, txn_data) do
    # Simplified: ATC || UN || truncated txn_data — real format varies by scheme
    atc <> un <> txn_data
  end

  # 3DES CBC-MAC: encrypt with all-zero IV, return last 8 bytes of result
  defp des3_cbc_mac(key_16, data) do
    padded  = pkcs7_pad(data, 8)
    iv      = <<0::64>>
    key_24  = key_16 <> binary_part(key_16, 0, 8)
    ciphered = :crypto.crypto_one_time(:des_ede3_cbc, key_24, iv, padded, true)
    binary_part(ciphered, byte_size(ciphered) - 8, 8)
  end

  defp des3_ecb_encrypt(key_16, data_8) do
    key_24 = key_16 <> binary_part(key_16, 0, 8)
    :crypto.crypto_one_time(:des_ede3_ecb, key_24, data_8, true)
  end

  defp pkcs7_pad(data, block_size) do
    pad_len = block_size - rem(byte_size(data), block_size)
    data <> :binary.copy(<<pad_len>>, pad_len)
  end

  # ---------------------------------------------------------------------------
  # PIN block decode (ISO 9564 Format-0)
  # ---------------------------------------------------------------------------

  # PIN block = XOR of PIN field and PAN field
  # PIN field  = 0 | PIN_len | PIN_digits | Fs
  # PAN field  = 0000 | rightmost-12-PAN-digits-excl-check-digit
  defp decode_pin_block(pin_block_hex, pan) do
    with {:ok, pin_block_bin} <- hex_decode(pin_block_hex) do
      pan_block = build_pan_block(pan)
      decoded   = :crypto.exor(pin_block_bin, pan_block)

      <<format::4, len::4, rest::binary>> = decoded

      with :ok <- validate_format(format),
           :ok <- validate_length(len) do
        pin_nibbles = extract_nibbles(rest, len)
        {:ok, Enum.join(pin_nibbles)}
      end
    end
  end

  # ISO 9564 Format-0 PAN block: 8 bytes
  # Nibbles: 0 0 0 0 | p1 p2 p3 p4 p5 p6 p7 p8 p9 p10 p11 p12
  # where p1..p12 are rightmost 12 PAN digits excluding check digit
  defp build_pan_block(pan) do
    pan_clean  = pan |> String.replace(~r/\D/, "")
    pan_no_chk = String.slice(pan_clean, 0..-2//1)
    pan_12     = pan_no_chk |> String.slice(-12..-1) |> String.pad_leading(12, "0")
    Base.decode16!("0000" <> pan_12, case: :mixed)
  end

  defp hex_decode(hex) when is_binary(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, bin} when byte_size(bin) == 8 -> {:ok, bin}
      {:ok, _}   -> {:error, :wrong_length}
      :error     -> {:error, :invalid_hex}
    end
  end

  defp validate_format(0), do: :ok
  defp validate_format(_), do: {:error, :unsupported_pin_format}

  defp validate_length(len) when len in 4..12, do: :ok
  defp validate_length(_), do: {:error, :invalid_pin_length}

  # Extract `n` nibbles from the high/low halves of each byte
  defp extract_nibbles(bin, n) do
    bin
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn byte -> [byte >>> 4, byte &&& 0x0F] end)
    |> Enum.take(n)
    |> Enum.map(&Integer.to_string/1)
  end

  # ---------------------------------------------------------------------------
  # PIN hash verification
  # ---------------------------------------------------------------------------

  defp verify_pin_against_stored(pin_digits, pan_token) do
    case Repo.one(from p in CardPin, where: p.pan_token == ^pan_token) do
      nil ->
        {:error, :pin_not_set}

      %CardPin{pin_locked_at: locked_at} when not is_nil(locked_at) ->
        {:error, :pin_blocked}

      %CardPin{} = card_pin ->
        check_and_update_pin(card_pin, pin_digits)
    end
  end

  defp check_and_update_pin(%CardPin{} = card_pin, pin_digits) do
    computed_hash = pbkdf2_hash(pin_digits, card_pin.pin_salt)

    if computed_hash == card_pin.pin_hash do
      # Reset try counter
      card_pin
      |> CardPin.reset_tries_changeset()
      |> Repo.update()

      :ok
    else
      max_tries = Application.get_env(:vmu_core, :pin_max_tries, 3)
      new_count = card_pin.try_counter + 1

      if new_count >= max_tries do
        card_pin
        |> CardPin.lock_changeset(DateTime.utc_now())
        |> Repo.update()

        {:error, :pin_blocked}
      else
        card_pin
        |> CardPin.increment_tries_changeset(new_count)
        |> Repo.update()

        {:error, :wrong_pin}
      end
    end
  end

  @pbkdf2_iters 100_000
  @pbkdf2_len   32

  defp pbkdf2_hash(pin, salt) do
    :crypto.pbkdf2_hmac(:sha256, pin, salt, @pbkdf2_iters, @pbkdf2_len)
    |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # Issuer script TLV builder
  # ---------------------------------------------------------------------------

  defp build_tlv(tag, value) when tag <= 0xFF do
    len = byte_size(value)
    encode_tlv_length(tag, len, value)
  end

  defp encode_tlv_length(tag, len, value) when len < 128 do
    <<tag::8, len::8>> <> value
  end

  defp encode_tlv_length(tag, len, value) when len < 256 do
    <<tag::8, 0x81, len::8>> <> value
  end

  defp encode_tlv_length(tag, len, value) do
    <<tag::8, 0x82, len::16>> <> value
  end

  # ---------------------------------------------------------------------------
  # Config helpers
  # ---------------------------------------------------------------------------

  defp get_cvk do
    case Application.get_env(:vmu_core, :soft_hsm, [])[:cvk] do
      nil -> nil
      hex when is_binary(hex) and byte_size(hex) == 16 -> hex
      hex when is_binary(hex) -> Base.decode16!(hex, case: :mixed)
      _ -> nil
    end
  end

  defp get_imk do
    case Application.get_env(:vmu_core, :soft_hsm, [])[:test_imk] do
      nil -> nil
      hex when is_binary(hex) and byte_size(hex) == 16 -> hex
      hex when is_binary(hex) -> Base.decode16!(hex, case: :mixed)
      _ -> nil
    end
  end

  defp arqc_verify_enabled? do
    Application.get_env(:vmu_core, :soft_hsm, [])[:arqc_verify_enabled] == true
  end

  defp pin_verify_enabled? do
    Application.get_env(:vmu_core, :soft_hsm, [pin_verify_enabled: true])
    |> Keyword.get(:pin_verify_enabled, true)
  end
end
