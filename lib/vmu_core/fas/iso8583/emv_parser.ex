defmodule VmuCore.FAS.ISO8583.EmvParser do
  @moduledoc """
  BER-TLV parser for ISO 8583 DE55 (Integrated Circuit Card Data) (FAS-P7 7F).

  DE55 carries EMV chip transaction data as BER-TLV encoded bytes. This parser
  extracts the tags relevant to issuer authorization:

  | Tag   | Name                             | Size    | Purpose              |
  |-------|----------------------------------|---------|----------------------|
  | 9F26  | Application Cryptogram (ARQC)    | 8       | Cryptogram to verify |
  | 9F37  | Unpredictable Number             | 4       | Anti-replay nonce    |
  | 9F36  | Application Transaction Counter  | 2       | Sequence / freshness |
  | 9F10  | Issuer Application Data          | var     | Issuer-specific data |
  | 84    | Dedicated File Name (AID)        | var     | Card application ID  |
  | 95    | Terminal Verification Results    | 5       | Risk checks done     |
  | 9B    | Transaction Status Information   | 2       | Terminal status      |
  | 5F2A  | Transaction Currency Code        | 2       | For script commands  |
  | 9F02  | Amount Authorised                | 6       | Txn amount in DE55   |

  ## Usage

      {:ok, emv} = EmvParser.parse(conn.params["de55_hex"])
      arqc = emv.arqc          # binary or nil
      atc  = emv.atc           # binary or nil

  Returns `{:ok, t()}` or `{:error, reason}`. Unknown tags are silently
  skipped — the parser is lenient on extra tags from different chip OS versions.
  """

  import Bitwise

  @type t :: %__MODULE__{
    arqc:         binary() | nil,
    unpredictable_no: binary() | nil,
    atc:          binary() | nil,
    iad:          binary() | nil,
    aid:          binary() | nil,
    tvr:          binary() | nil,
    tsi:          binary() | nil,
    currency_code: binary() | nil,
    amount:       binary() | nil,
    raw_tags:     [{binary(), binary()}]
  }

  defstruct [
    :arqc, :unpredictable_no, :atc, :iad, :aid, :tvr, :tsi,
    :currency_code, :amount,
    raw_tags: []
  ]

  @doc """
  Parse DE55 from a hex string (e.g. as received in a JSON API or the raw field).
  """
  @spec parse(String.t() | binary()) :: {:ok, t()} | {:error, term()}
  def parse(hex_or_bin) when is_binary(hex_or_bin) do
    bin =
      if String.match?(hex_or_bin, ~r/^[0-9A-Fa-f]+$/) and rem(byte_size(hex_or_bin), 2) == 0 do
        Base.decode16!(hex_or_bin, case: :mixed)
      else
        hex_or_bin
      end

    case parse_tlv(bin) do
      {:ok, tags} ->
        emv = build_emv_struct(tags)
        {:ok, emv}

      {:error, _} = err ->
        err
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  # ---------------------------------------------------------------------------
  # BER-TLV recursive parser
  # ---------------------------------------------------------------------------

  @spec parse_tlv(binary()) :: {:ok, [{binary(), binary()}]} | {:error, term()}
  def parse_tlv(data), do: parse_tlv(data, [])

  defp parse_tlv(<<>>, acc), do: {:ok, Enum.reverse(acc)}

  defp parse_tlv(data, acc) do
    with {:ok, tag, rest}   <- read_tag(data),
         {:ok, len, rest}   <- read_length(rest),
         {:ok, value, rest} <- read_value(rest, len) do
      parse_tlv(rest, [{tag, value} | acc])
    end
  end

  # Tag parsing: handle single-byte and multi-byte (high-5-bits-set) tags
  defp read_tag(<<first_byte, rest::binary>>) do
    if (first_byte &&& 0x1F) == 0x1F do
      read_long_tag(rest, <<first_byte>>)
    else
      {:ok, <<first_byte>>, rest}
    end
  end

  defp read_tag(<<>>), do: {:error, :empty_tag}

  defp read_long_tag(<<byte, rest::binary>>, acc) do
    new_acc = acc <> <<byte>>
    if (byte &&& 0x80) == 0x80 do
      read_long_tag(rest, new_acc)
    else
      {:ok, new_acc, rest}
    end
  end

  defp read_long_tag(<<>>, _acc), do: {:error, :truncated_tag}

  # Length parsing: short form (< 128) or long form
  defp read_length(<<0x80, _rest::binary>>), do: {:error, :indefinite_length_not_supported}

  defp read_length(<<len_byte, rest::binary>>) when len_byte < 0x80 do
    {:ok, len_byte, rest}
  end

  defp read_length(<<0x81, len::8, rest::binary>>) do
    {:ok, len, rest}
  end

  defp read_length(<<0x82, len::16, rest::binary>>) do
    {:ok, len, rest}
  end

  defp read_length(<<len_byte, _::binary>>) when len_byte > 0x82 do
    {:error, {:unsupported_length_encoding, len_byte}}
  end

  defp read_length(<<>>), do: {:error, :empty_length}

  # Value extraction
  defp read_value(data, len) when byte_size(data) >= len do
    <<value::bytes-size(len), rest::binary>> = data
    {:ok, value, rest}
  end

  defp read_value(_data, _len), do: {:error, :truncated_value}

  # ---------------------------------------------------------------------------
  # Map raw tag list to structured EMV fields
  # ---------------------------------------------------------------------------

  defp build_emv_struct(tags) do
    tag_map = Map.new(tags, fn {t, v} -> {Base.encode16(t, case: :lower), v} end)

    %__MODULE__{
      arqc:             Map.get(tag_map, "9f26"),
      unpredictable_no: Map.get(tag_map, "9f37"),
      atc:              Map.get(tag_map, "9f36"),
      iad:              Map.get(tag_map, "9f10"),
      aid:              Map.get(tag_map, "84"),
      tvr:              Map.get(tag_map, "95"),
      tsi:              Map.get(tag_map, "9b"),
      currency_code:    Map.get(tag_map, "5f2a"),
      amount:           Map.get(tag_map, "9f02"),
      raw_tags:         tags
    }
  end
end
