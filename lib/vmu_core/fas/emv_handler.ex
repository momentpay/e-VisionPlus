defmodule VmuCore.FAS.EmvHandler do
  @moduledoc """
  EMV chip authorization processing (FAS-P7 7G + 7H).

  ## 7G — ARQC Verification + ARPC Generation

  When DE55 is present in the 0100 request:
  1. `EmvParser.parse/1` extracts ARQC (9F26), ATC (9F36), UN (9F37)
  2. `HSM.verify_arqc/5` cryptographically verifies the chip cryptogram
  3. If approved, `HSM.generate_arpc/3` builds the Issuer Authentication Data
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

          {:ok, %EmvParser{arqc: arqc, atc: atc, unpredictable_no: un}} ->
            txn_data = build_txn_data(fields)
            atc  = atc  || <<0, 0>>
            un   = un   || <<0, 0, 0, 0>>
            HSM.verify_arqc(pan_token, atc, un, txn_data, arqc)

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
        with {:ok, emv}   <- EmvParser.parse(de55),
             {:ok, arpc}  <- build_arpc(emv, rc, pan_token),
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
    ISOMsg.set(msg, 55, Base.encode16(de55_bin, case: :lower))
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_arpc(%EmvParser{arqc: nil}, _rc, _pan_token), do: {:ok, <<0::64>>}

  defp build_arpc(%EmvParser{arqc: arqc}, rc, pan_token) do
    arc = rc_to_arc(rc)
    HSM.generate_arpc(arqc, arc, pan_token)
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

  # Serialize transaction data elements for ARQC input (simplified)
  # Real implementation would follow EMV Book 3 Appendix B format
  defp build_txn_data(fields) do
    amount   = Map.get(fields, 4,  "") |> String.pad_leading(12, "0")
    currency = Map.get(fields, 49, "784") |> String.pad_leading(3, "0")
    date     = Map.get(fields, 13, "000000") |> String.pad_leading(6, "0")

    (amount <> currency <> date)
    |> Base.decode16(case: :mixed)
    |> case do
      {:ok, bin} -> bin
      _          -> <<0::80>>
    end
  end
end
