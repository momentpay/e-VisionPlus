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
        test_imk:           nil,      # 16-byte Issuer Master Key (per Book 2 Annex A1.3)
        test_psn:           "00"      # PAN Sequence Number, EMV tag 5F34 (default "00")

  ## CVV Algorithm

  Implements the Visa/MC 3DES CVV generation algorithm:
    1. Build 32 hex-char string: PAN (sans check digit) + YYMM + service_code
    2. Split into two 8-byte blocks; DES-ECB encrypt first block with CVK left half
    3. XOR result with second block; 3DES-ECB encrypt with full CVK
    4. Decimalize: extract digits first, then A-F → 0-5
    5. First 3 characters = CVV value

  ## ARQC Verification (Phase 12 Part B — real EMV Book 2/3 conformance)

  When `arqc_verify_enabled: false` (default in dev), all ARQCs are accepted
  with a debug log. Set to `true` only when a valid test IMK is configured —
  without matching key material, every real ARQC will fail verification.

  Real 3-stage EMV key derivation (not an approximation — see the "ARQC
  internals" section below for exact citations):
    1. ICC Master Key = derive(IMK, PAN, PSN)          — Book 2 Annex A1.3
    2. Session Key    = derive(ICC Master Key, ATC)    — Book 2 Annex A1.4
    3. Application Cryptogram = retail-MAC(Session Key, CDOL1 data)
                                                        — Book 2 Annex A1.2,
                                                          ISO/IEC 9797-1 MAC
                                                          Algorithm 3

  ## PIN Verification (redesigned 2026-07-24, Way4 parity plan Phase 0 item 7)

  `verify_pin/3` decodes the real ISO 9564 Format-0 PIN block (XOR with the
  real PAN — `verify_pin/3` has it, from DE52's caller context) and compares
  the recovered digits against `CardPin.reference_pin_lmk`, never persisting
  or returning the recovered digits — mirrors the real HSM's "comparison
  method" (payShield's BE command), just simulated with a dev-only key
  instead of an LMK. Try counter incremented on each wrong PIN; card locked
  after `max_pin_tries` (from logo params, default 3); reset on success.

  `change_pin/3` **cannot** use the real ISO PAN-bound format — self-service
  channels (IVR/app/web) only ever have `pan_token`, never the real PAN, by
  this codebase's own "never store/transmit raw PAN outside a live network
  message" policy (see `VmuCore.FAS.HSM.change_pin/3`'s moduledoc). Every
  real payShield PIN-reference command (BE, BK, DG, JE) is PAN-bound by
  format — there is no vendor command that produces a valid reference
  without it. So `reference_pin_lmk` is instead stored as the new PIN
  digits encrypted under a dev-only key, with no PAN mixed in — a
  dev-mode-only simplification (SoftHSM is already not-for-production),
  not the real ISO format. `verify_pin/3` decrypts a stored reference back
  to plain digits internally to compare against the real-format block it
  decoded — the real ISO decode path is exercised end-to-end even though
  the stored reference itself isn't ISO-formatted.
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

  @impl VmuCore.FAS.HSM
  def generate_cvv(pan, expiry, service_code) do
    case get_cvk() do
      nil ->
        Logger.debug("[SoftHSM] CVK not configured — returning a fixed dev CVV")
        {:ok, "000"}

      cvk ->
        {:ok, compute_cvv(pan, expiry, service_code, cvk)}
    end
  end

  # ---------------------------------------------------------------------------
  # ARQC Verification (7G)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def verify_arqc(pan, pan_token, atc, _un, txn_data, arqc) do
    if arqc_verify_enabled?() do
      imk = get_imk()

      if is_nil(imk) do
        Logger.warning("[SoftHSM] ARQC verify enabled but IMK not configured — fail-open")
        :ok
      else
        # txn_data is the real CDOL1 data (EmvHandler.build_txn_data/1) —
        # already includes the Unpredictable Number as one of its own
        # fields (EMV Book 3 Appendix B), so it isn't prepended separately
        # here the way the old simplified format did.
        icc_mk      = derive_icc_master_key(imk, pan, get_psn())
        session_key = derive_session_key(icc_mk, atc)
        expected    = compute_application_cryptogram(session_key, txn_data)

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
  def generate_arpc(pan, atc, _un, arqc, arc, pan_token) do
    imk = get_imk()

    if is_nil(imk) do
      # Synthetic ARPC: XOR ARQC with ARC padded to 8 bytes (no real session key)
      arc_padded  = arc <> :binary.copy(<<0>>, 8 - byte_size(arc))
      arpc = :crypto.exor(arqc, arc_padded)
      {:ok, arpc}
    else
      # Real ARPC: Method 1 — XOR ARQC with ARC, encrypt with the SAME
      # session key verify_arqc/6 derives from this same PAN/ATC (real
      # PAN-diversified ICC Master Key derivation, EMV Book 2 Annex A1.3 —
      # previously this used the flat IMK directly, skipping that step).
      _ = pan_token  # suppress unused warning
      icc_mk       = derive_icc_master_key(imk, pan, get_psn())
      session_key  = derive_session_key(icc_mk, atc)
      arc_padded   = arc <> :binary.copy(<<0>>, 8 - byte_size(arc))
      intermediate = :crypto.exor(arqc, arc_padded)
      arpc         = des3_ecb_encrypt(session_key, intermediate)
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
  # ZPK decrypt (Phase 10 — end-to-end PIN translation)
  # ---------------------------------------------------------------------------

  # Before this, verify_pin/3 assumed pin_block_hex arrived already in the
  # clear ISO 9564-1 (PIN field XOR PAN field) form — real network traffic
  # never looks like that; it's encrypted under whatever ZPK the network
  # leg's HSM translated it to. Real end-to-end verification needs this
  # decrypt step decode_pin_block/2 was always missing. Matches
  # `HsmSimulator.Crypto.ecb_decrypt/2`'s exact key expansion (2-key
  # triple-DES, K1|K2|K1) and its ECB-via-zero-IV-CBC technique — this
  # environment's OpenSSL doesn't expose :des_ede3_ecb/:des_ecb as ciphers
  # at all (`:crypto.supports(:ciphers)` confirms only the CBC/CFB 3DES
  # variants are available), the same gap this module's own CVV code
  # (des_ecb/des_ede3_ecb, above) would hit if ever actually exercised —
  # it isn't by default, since CVV verification is skipped when no CVK is
  # configured, which is why this wasn't already visible here.
  defp maybe_decrypt_under_zpk(pin_block_bin) do
    case get_zpk() do
      nil -> pin_block_bin
      zpk -> ecb_decrypt_via_cbc(zpk, pin_block_bin)
    end
  end

  defp ecb_decrypt_via_cbc(key16, data) when byte_size(key16) == 16 do
    key24 = binary_part(key16, 0, 8) <> binary_part(key16, 8, 8) <> binary_part(key16, 0, 8)

    for(<<block::binary-8 <- data>>, do: block)
    |> Enum.map(&:crypto.crypto_one_time(:des_ede3_cbc, key24, <<0::64>>, &1, false))
    |> :binary.list_to_bin()
  end

  defp get_zpk do
    case Application.get_env(:vmu_core, :soft_hsm, [])[:zpk] do
      nil -> nil
      hex when is_binary(hex) and byte_size(hex) == 16 -> hex
      hex when is_binary(hex) -> Base.decode16!(hex, case: :mixed)
      _ -> nil
    end
  end

  @doc false
  # Exposed for VmuCore.FAS.HSM.ProductionHSM's dev/test fallback and
  # tests only — dev-mode-only "encrypt digits under a fixed key" used
  # for reference_pin_lmk (see moduledoc: change_pin/3 has no PAN, so it
  # cannot produce a real ISO-formatted reference).
  def encrypt_reference_dev(pin_digits) when is_binary(pin_digits) do
    key = dev_reference_key()
    padded = String.pad_trailing(pin_digits, 16, "F")
    :crypto.crypto_one_time(:aes_128_ecb, key, padded, true) |> Base.encode16(case: :lower)
  end

  # ---------------------------------------------------------------------------
  # PIN Change (self-service channels — plaintext digits, no PAN available)
  # ---------------------------------------------------------------------------

  @impl VmuCore.FAS.HSM
  def change_pin(pan_token, old_pin, new_pin) do
    if valid_pin_format?(new_pin) do
      case Repo.one(from p in CardPin, where: p.pan_token == ^pan_token) do
        nil ->
          {:error, :pin_not_set}

        %CardPin{pin_locked_at: locked_at} when not is_nil(locked_at) ->
          {:error, :pin_blocked}

        %CardPin{} = card_pin ->
          case check_old_pin(card_pin, old_pin) do
            :ok -> store_new_pin(card_pin, new_pin)
            error -> error
          end
      end
    else
      {:error, :invalid_pin_format}
    end
  end

  defp valid_pin_format?(pin), do: is_binary(pin) and String.match?(pin, ~r/^\d{4,6}$/)

  # Same dev-only "encrypted digits" reference change_pin/3 stores — see
  # moduledoc for why this can't be the real ISO/PAN-bound format.
  defp check_old_pin(%CardPin{reference_pin_lmk: nil}, _old_pin), do: {:error, :pin_not_set}

  defp check_old_pin(%CardPin{reference_pin_lmk: ref}, old_pin) do
    if decrypt_reference_dev(ref) == old_pin, do: :ok, else: {:error, :wrong_pin}
  end

  defp store_new_pin(%CardPin{} = card_pin, new_pin) do
    card_pin
    |> CardPin.set_reference_changeset(encrypt_reference_dev(new_pin))
    |> Repo.update()
    |> case do
      {:ok, _}    -> :ok
      {:error, _} = err -> err
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

    # DES ECB encrypt block1 with left half of CVK (single_des_ecb_encrypt/2 —
    # this environment's OpenSSL doesn't expose :des_ecb as a cipher, see
    # that function's own moduledoc note above)
    e1 = single_des_ecb_encrypt(cvk_a, block1)

    # XOR e1 with block2
    xor_result = :crypto.exor(e1, block2)

    # 3DES ECB encrypt with full CVK (2-key → K1|K2|K1, done inside des3_ecb_encrypt/2)
    e2 = des3_ecb_encrypt(cvk, xor_result)

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
  # ARQC internals — real EMV Book 2 Annex A1 key derivation + Application
  # Cryptogram (ISO/IEC 9797-1 MAC Algorithm 3 / ANSI X9.19 "retail MAC").
  #
  # This environment's OpenSSL doesn't expose :des_ede3_ecb or single-length
  # :des_ecb/:des_cbc as ciphers at all (:crypto.supports(:ciphers) confirms
  # only :des_ede3_cbc/:des_ede3_cfb are available — same gap Phase 10's PIN
  # block work hit). Two exact, not-approximate workarounds, both used
  # throughout this section:
  #   - 3DES-ECB(key16, block) = 3DES-CBC(key16, iv: zero, block) applied per
  #     independent 8-byte block (CBC's first step XORs a zero IV into the
  #     plaintext, a no-op) — same technique Phase 10 established.
  #   - single-DES-ECB(key8, block) = 3DES-EDE(key8|key8|key8, block) via the
  #     same zero-IV-CBC technique — 3DES-EDE degenerates to plain single-DES
  #     when all three key positions are equal (Encrypt-Decrypt-Encrypt with
  #     the same key cancels the middle Decrypt/Encrypt pair), a standard,
  #     documented property, not an approximation.

  # EMV Book 2 Annex A1.3 (Option A): ICC Master Key = 3DES-ECB(IMK, ·)
  # applied to the rightmost 16 digits of PAN||PSN (BCD, left-padded with
  # "0"), and to its ones'-complement, concatenated.
  defp derive_icc_master_key(imk, pan, psn) do
    digits   = (pan <> psn) |> String.replace(~r/\D/, "")
    input_16 = digits |> String.slice(-16..-1) |> String.pad_leading(16, "0")
    input    = bcd_encode(input_16)

    zl = des3_ecb_encrypt(imk, input)
    zr = des3_ecb_encrypt(imk, complement(input))
    zl <> zr
  end

  # EMV Book 2 Annex A1.4 (Common Session Key Derivation): Session Key =
  # 3DES-ECB(ICC_MK, ·) applied to ATC||F0F0||000000 and ATC||0F0F||000000.
  defp derive_session_key(icc_mk, atc) when byte_size(atc) == 2 do
    rl = atc <> <<0xF0, 0xF0>> <> <<0, 0, 0, 0>>
    rr = atc <> <<0x0F, 0x0F>> <> <<0, 0, 0, 0>>

    des3_ecb_encrypt(icc_mk, rl) <> des3_ecb_encrypt(icc_mk, rr)
  end

  # EMV Book 2 Annex A1.2 — the Application Cryptogram is the real ISO/IEC
  # 9797-1 MAC Algorithm 3 ("retail MAC"), not uniform 3DES-CBC-MAC: split
  # the session key into two SINGLE-length DES keys SK1/SK2; every block
  # (including the last) chains under single-DES with SK1; only the final
  # chained value gets the extra encrypt(SK1, decrypt(SK2, ·)) step. Getting
  # this single-vs-final-triple distinction right is the actual spec.
  defp compute_application_cryptogram(<<sk1::binary-8, sk2::binary-8>>, data) do
    hn =
      data
      |> iso7816_4_pad(8)
      |> then(&for(<<block::binary-8 <- &1>>, do: block))
      |> Enum.reduce(<<0::64>>, fn block, acc ->
        single_des_ecb_encrypt(sk1, :crypto.exor(acc, block))
      end)

    single_des_ecb_encrypt(sk1, single_des_ecb_decrypt(sk2, hn))
  end

  # ISO/IEC 7816-4 padding method 2: append 0x80, then zero-pad to the next
  # block boundary. EMV always applies this, even to already-aligned data.
  defp iso7816_4_pad(data, block_size) do
    marked = data <> <<0x80>>
    pad_len = rem(block_size - rem(byte_size(marked), block_size), block_size)
    marked <> :binary.copy(<<0>>, pad_len)
  end

  defp bcd_encode(digit_string) do
    digit_string
    |> String.to_charlist()
    |> Enum.map(&(&1 - ?0))
    |> Enum.chunk_every(2)
    |> Enum.map(fn [hi, lo] -> (hi <<< 4) ||| lo end)
    |> :binary.list_to_bin()
  end

  defp complement(data), do: :crypto.exor(data, :binary.copy(<<0xFF>>, byte_size(data)))

  defp des3_ecb_encrypt(key_16, data_8) do
    key_24 = key_16 <> binary_part(key_16, 0, 8)
    :crypto.crypto_one_time(:des_ede3_cbc, key_24, <<0::64>>, data_8, true)
  end

  defp single_des_ecb_encrypt(key_8, data_8) do
    key_24 = key_8 <> key_8 <> key_8
    :crypto.crypto_one_time(:des_ede3_cbc, key_24, <<0::64>>, data_8, true)
  end

  defp single_des_ecb_decrypt(key_8, data_8) do
    key_24 = key_8 <> key_8 <> key_8
    :crypto.crypto_one_time(:des_ede3_cbc, key_24, <<0::64>>, data_8, false)
  end

  # ---------------------------------------------------------------------------
  # PIN block decode (ISO 9564 Format-0)
  # ---------------------------------------------------------------------------

  # PIN block = XOR of PIN field and PAN field
  # PIN field  = 0 | PIN_len | PIN_digits | Fs
  # PAN field  = 0000 | rightmost-12-PAN-digits-excl-check-digit
  defp decode_pin_block(pin_block_hex, pan) do
    with {:ok, pin_block_bin} <- hex_decode(pin_block_hex) do
      clear_block = maybe_decrypt_under_zpk(pin_block_bin)
      pan_block = build_pan_block(pan)
      decoded   = :crypto.exor(clear_block, pan_block)

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

      %CardPin{reference_pin_lmk: nil} ->
        {:error, :pin_not_set}

      %CardPin{} = card_pin ->
        check_and_update_pin(card_pin, pin_digits)
    end
  end

  defp check_and_update_pin(%CardPin{} = card_pin, pin_digits) do
    if decrypt_reference_dev(card_pin.reference_pin_lmk) == pin_digits do
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

  defp decrypt_reference_dev(reference_hex) do
    key = dev_reference_key()

    reference_hex
    |> Base.decode16!(case: :mixed)
    |> then(&:crypto.crypto_one_time(:aes_128_ecb, key, &1, false))
    |> String.trim_trailing("F")
  end

  # Fixed, non-configurable dev-only key — this is a simplification for
  # SoftHSM's own internal reference storage, not a real ZPK/LMK; never
  # used to protect anything outside this explicitly not-for-production
  # module. Not derived from any real key material.
  defp dev_reference_key, do: :crypto.hash(:sha256, "soft_hsm_dev_reference_key") |> binary_part(0, 16)

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

  # PAN Sequence Number (EMV tag 5F34) — a fixed test value, matching this
  # codebase's key-material convention (Phase 10): both ends (issuer here,
  # TerminalEmulator.Emv) agree on the same value directly rather than
  # transmitting it, same as the "conventional test values" already used
  # for the CVK/PIN keys.
  defp get_psn, do: Application.get_env(:vmu_core, :soft_hsm, [])[:test_psn] || "00"

  defp arqc_verify_enabled? do
    Application.get_env(:vmu_core, :soft_hsm, [])[:arqc_verify_enabled] == true
  end

  defp pin_verify_enabled? do
    Application.get_env(:vmu_core, :soft_hsm, [pin_verify_enabled: true])
    |> Keyword.get(:pin_verify_enabled, true)
  end
end
