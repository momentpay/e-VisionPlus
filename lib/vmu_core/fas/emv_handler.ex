defmodule VmuCore.FAS.EmvHandler do
  @moduledoc """
  EMV chip authorization processing (FAS-P7 7G + 7H).

  ## 7G — ARQC Verification + ARPC Generation

  When DE55 is present in the 0100 request:
  1. `EmvParser.parse/1` extracts ARQC (9F26), ATC (9F36), UN (9F37)
  2. `HSM.verify_arqc/6` cryptographically verifies the chip cryptogram
  3. If approved, `HSM.generate_arpc/6` builds the Issuer Authentication Data
  4. The ARPC is returned as a DE55 fragment for inclusion in the 0110 response

  ## 7H — Issuer Scripts

  Conditions that trigger issuer scripts:
    - `script_commands/2` is called with the account status and authorization RC
    - `:block_card` if the account was suspended/closed during this auth
    - `:reset_pin_tries` if the approval clears a PIN-locked card (OPS scenario)

  Script TLV (tags 71/72) is built by `HSM.build_issuer_scripts/2` and appended
  to DE55 in the 0110 response.

  ## Fail-open

  ARQC verification failures do not auto-decline the transaction — the issuer
  authorizes based on the card record checks (OTB, status, CVV, etc.) and only
  the cryptogram signals chip authenticity. If ARQC fails, `rc_override/1`
  returns `:decline` — issuers choosing fail-open should override this by
  configuring `config :vmu_core, :arqc_decline_on_fail, false`.
  """

  require Logger

  alias VmuCore.FAS.{HSM, ISO8583.EmvParser}
  alias DaSwitchCore.Packagers.ISOMsg

  @doc """
  Verify the ARQC from DE55. Returns `:ok`, `{:error, :arqc_mismatch}`, or
  `:skip` when DE55 is absent.
  """
  @spec verify_arqc(map()) :: :ok | :skip | {:error, :arqc_mismatch}
  def verify_arqc(%{fields: fields, pan_token: pan_token}) do
    case Map.get(fields, 55) do
      nil ->
        :skip

      de55 ->
        case EmvParser.parse(de55) do
          {:ok, %EmvParser{arqc: nil}} ->
            Logger.debug("[EMV] DE55 present but no ARQC tag 9F26")
            :skip

          {:ok, %EmvParser{arqc: arqc, atc: atc, unpredictable_no: un} = emv} ->
            txn_data = build_txn_data(fields, emv)
            atc  = atc  || <<0, 0>>
            un   = un   || <<0, 0, 0, 0>>
            pan  = Map.get(fields, 2, "")
            HSM.verify_arqc(pan, pan_token, atc, un, txn_data, arqc)

          {:error, reason} ->
            Logger.warning("[EMV] DE55 parse failed: #{inspect(reason)}")
            :skip
        end
    end
  end

  @doc """
  Build the DE55 content for the 0110 response.

  Includes:
  - Tag 8A: Authorization Response Code (2 bytes from RC string)
  - Tag 91: Issuer Authentication Data (ARPC, 8 bytes)
  - Tags 71/72: Issuer scripts (if any commands)
  """
  @spec build_response_de55(map(), String.t(), [atom()]) ::
          {:ok, binary()} | {:error, term()}
  def build_response_de55(%{fields: fields, pan_token: pan_token}, rc, script_commands) do
    case Map.get(fields, 55) do
      nil ->
        {:ok, nil}

      de55 ->
        pan = Map.get(fields, 2, "")

        with {:ok, emv}   <- EmvParser.parse(de55),
             {:ok, arpc}  <- build_arpc(pan, emv, rc, pan_token),
             {:ok, scripts} <- build_scripts(pan_token, script_commands) do
          # Tag 8A = Authorization Response Code: 2 ASCII bytes of RC
          arc_bytes  = <<String.to_integer(String.at(rc, 0)), String.to_integer(String.at(rc, 1))>>
          arc_tlv    = <<0x8A, 0x02>> <> arc_bytes

          # Tag 91 = Issuer Authentication Data: ARPC (8 bytes)
          arpc_tlv   = <<0x91, byte_size(arpc)>> <> arpc

          response_de55 = arc_tlv <> arpc_tlv <> scripts
          {:ok, response_de55}
        end
    end
  end

  @doc """
  Determines which issuer script commands should be sent based on auth outcome.

  Returns a list of atoms passed to `HSM.build_issuer_scripts/2`.
  """
  @spec script_commands(map(), String.t()) :: [atom()]
  def script_commands(%{account_status: "BLOCKED"}, _rc),    do: [:block_card]
  def script_commands(%{account_status: "SUSPENDED"}, _rc),  do: [:block_card]
  def script_commands(%{pin_was_locked: true}, "00"),         do: [:reset_pin_tries]
  def script_commands(_ctx, _rc),                             do: []

  @doc """
  Inject DE55 response into an existing ISOMsg if `response_de55` is non-nil binary.
  """
  @spec inject_de55(ISOMsg.t(), binary() | nil) :: ISOMsg.t()
  def inject_de55(msg, nil), do: msg

  def inject_de55(msg, de55_bin) do
    # DE55's field packager (ISO87BPackager) is {:binary_interpreter} — raw
    # binary, no encoding transformation (same as DE52's IFB_BINARY, see
    # Phase 10's finding: a hex-encoded string here silently desyncs the
    # wire layout instead of erroring). Set the raw bytes directly.
    ISOMsg.set(msg, 55, de55_bin)
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_arpc(_pan, %EmvParser{arqc: nil}, _rc, _pan_token), do: {:ok, <<0::64>>}

  defp build_arpc(pan, %EmvParser{arqc: arqc, atc: atc, unpredictable_no: un}, rc, pan_token) do
    arc = rc_to_arc(rc)
    atc = atc || <<0, 0>>
    un  = un  || <<0, 0, 0, 0>>
    HSM.generate_arpc(pan, atc, un, arqc, arc, pan_token)
  end

  defp build_scripts(pan_token, []) do
    {:ok, <<>>}
  end

  defp build_scripts(pan_token, commands) do
    HSM.build_issuer_scripts(pan_token, commands)
  end

  # Authorization Response Code → 2-byte ARC for ARPC Method 1
  defp rc_to_arc("00"), do: <<0x00, 0x00>>
  defp rc_to_arc("05"), do: <<0x05, 0x10>>
  defp rc_to_arc("51"), do: <<0x05, 0x10>>
  defp rc_to_arc("61"), do: <<0x06, 0x00>>
  defp rc_to_arc(_),    do: <<0x05, 0x30>>  # generic decline

  # Real CDOL1 transaction data (Phase 12 Part B), replacing the previous
  # simplified format — that one concatenated amount(12)+currency(3)+date(6)
  # = 21 ASCII digit characters (odd length) and hex-decoded the result,
  # which ALWAYS failed (Base.decode16 requires even length) and silently
  # fell back to all-zero bytes; ARQC verification was never actually
  # exercised end-to-end before this phase, which is why that went unnoticed.
  #
  # There's no physical card here to read a real CDOL1 list from, so this
  # is one fixed, realistic field set both this module and
  # TerminalEmulator.Emv (the terminal-side "virtual chip") agree on —
  # documented once here, mirrored exactly on the terminal side, the same
  # principle Phase 10 used for the ISO 9564-1 PIN block. Field order and
  # BCD encoding follow EMV Book 3 Appendix B / Book 4 Table.
  #
  # Amount/currency/date come from the ISO message's own DE4/DE49/DE13 (the
  # actual transaction data); the chip/terminal-risk fields (TVR, AIP,
  # terminal country/type) come from DE55 itself, since nothing else in the
  # ISO message carries them. DE13 (this codebase's convention, see
  # TerminalEmulator.Packet) is MMDD only — no year is transmitted on the
  # wire in real ISO 8583 either, so the current year is combined in here,
  # same as any real host would.
  defp build_txn_data(fields, %EmvParser{} = emv) do
    amount_authorised = bcd(Map.get(fields, 4, "0"), 12)
    amount_other       = <<0::48>>
    terminal_country   = emv.terminal_country_code || <<0x07, 0x84>>
    tvr                = emv.tvr || <<0, 0, 0, 0, 0>>
    currency           = bcd(Map.get(fields, 49, "784"), 4)
    date               = bcd(current_year_2digit() <> Map.get(fields, 13, "0000"), 6)
    txn_type           = bcd(Map.get(fields, 3, "00") |> String.slice(0, 2), 2)
    un                 = emv.unpredictable_no || <<0, 0, 0, 0>>
    terminal_type      = emv.terminal_type || <<0x22>>
    aip                = emv.aip || <<0, 0>>

    amount_authorised <> amount_other <> terminal_country <> tvr <>
      currency <> date <> txn_type <> un <> terminal_type <> aip
  end

  defp current_year_2digit do
    Date.utc_today().year |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
  end

  defp bcd(digit_string, target_digit_count) do
    digit_string
    |> String.replace(~r/\D/, "")
    |> String.pad_leading(target_digit_count, "0")
    |> String.slice(-target_digit_count, target_digit_count)
    |> String.to_charlist()
    |> Enum.map(&(&1 - ?0))
    |> Enum.chunk_every(2)
    |> Enum.map(fn [hi, lo] -> hi * 16 + lo end)
    |> :binary.list_to_bin()
  end
end
