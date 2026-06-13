defmodule VmuCore.TRAMS.VisaBaseII do
  @moduledoc """
  Visa Base II clearing file parser.

  Base II is a fixed-width EBCDIC-encoded format transmitted via VisaNet.
  Each file contains 80-byte records with a 2-byte record type identifier.

  Record types:
    TC05 — Transaction Detail Record (the clearing record)
    TC15 — Fee Collection Record
    TC25 — Funds Disbursement Record
    TC46 — Retrieval Request
    TC50 — Chargeback Record

  This parser handles TC05 (primary clearing) and TC50 (chargebacks, forwarded to DPS).
  """

  require Logger
  alias VmuCore.TRAMS.ClearingRecord
  alias VmuCore.{Repo, CMS.Account, DPS.Dispute}
  import Ecto.Query

  @record_length 80

  @doc "Parse a Base II file and return clearing record attrs."
  def parse_file(file_path) do
    Logger.info("[TRAMS/BaseII] Parsing file: #{file_path}")

    case File.read(file_path) do
      {:ok, binary} ->
        records = parse_records(binary, file_path)
        Logger.info("[TRAMS/BaseII] Parsed #{length(records)} records")
        {:ok, records}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Process file end-to-end. Chargebacks are forwarded to DPS.Dispute.file/1."
  def process_file(file_path) do
    with {:ok, records} <- parse_file(file_path) do
      tc05 = Enum.filter(records, &(&1.record_type == "TC05"))
      tc50 = Enum.filter(records, &(&1.record_type == "TC50"))

      clearing_results = Enum.map(tc05, fn attrs ->
        result = Repo.insert(ClearingRecord.changeset(%ClearingRecord{}, attrs))
        case result do
          {:ok, rec} when not is_nil(rec.account_id) ->
            VmuCore.ITS.FeeClaimProcessor.create_claim(rec)
          _ -> :ok
        end
        result
      end)
      chargeback_results = Enum.map(tc50, &handle_chargeback/1)

      {:ok, %{
        clearing_inserted: Enum.count(clearing_results, &match?({:ok, _}, &1)),
        chargebacks_filed: Enum.count(chargeback_results, &match?({:ok, _}, &1))
      }}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp parse_records(binary, file_name) do
    binary
    |> split_records()
    |> Enum.map(&decode_record(&1, file_name))
    |> Enum.reject(&is_nil/1)
  end

  defp split_records(binary) do
    total = byte_size(binary)
    count = div(total, @record_length)
    for i <- 0..(count - 1), do: binary_part(binary, i * @record_length, @record_length)
  end

  defp decode_record(record, file_name) do
    try do
      # Base II records are EBCDIC — convert to ASCII for parsing
      ascii = ebcdic_to_ascii(record)
      record_type = String.slice(ascii, 0, 4)

      case record_type do
        "TC05" ->
          %{
            network:          "VI",
            file_name:        Path.basename(file_name),
            record_type:      "TC05",
            pan_token:        extract_pan_token(ascii),
            amount:           extract_amount(ascii, 16, 12),
            currency:         extract_currency(ascii),
            transaction_date: extract_date(ascii, 28),
            rrn:              String.trim(String.slice(ascii, 44, 12)),
            auth_code:        String.trim(String.slice(ascii, 56, 6)),
            mcc:              String.trim(String.slice(ascii, 62, 4)),
            match_status:     "UNMATCHED"
          }

        "TC50" ->
          %{
            network:          "VI",
            file_name:        Path.basename(file_name),
            record_type:      "TC50",
            pan_token:        extract_pan_token(ascii),
            amount:           extract_amount(ascii, 16, 12),
            currency:         extract_currency(ascii),
            transaction_date: extract_date(ascii, 28),
            rrn:              String.trim(String.slice(ascii, 44, 12)),
            reason_code:      String.trim(String.slice(ascii, 66, 4))
          }

        _ -> nil
      end
    rescue
      e ->
        Logger.warning("[TRAMS/BaseII] Decode failed: #{inspect(e)}")
        nil
    end
  end

  defp handle_chargeback(%{pan_token: pan_token, amount: amount, transaction_date: txn_date, reason_code: rc}) do
    account_id = Repo.one(from a in Account, where: a.pan_token == ^pan_token, select: a.account_id)

    if account_id do
      Dispute.file(%{
        account_id:       account_id,
        transaction_date: txn_date,
        dispute_amount:   amount,
        reason_code:      rc,
        network:          "VI"
      })
    else
      {:error, :account_not_found}
    end
  end

  # EBCDIC to ASCII conversion table (IBM Code Page 500 subset)
  defp ebcdic_to_ascii(binary) do
    binary
    |> :binary.bin_to_list()
    |> Enum.map(&ebcdic_char/1)
    |> List.to_string()
  rescue
    _ -> binary
  end

  defp ebcdic_char(c) when c in 0x40..0xFF do
    table = %{
      0x40 => ?\s, 0x4B => ?., 0x4C => ?<, 0x4D => ?(, 0x4E => ?+, 0x4F => ?|,
      0x50 => ?&, 0x5B => ?$, 0x5C => ?*, 0x5D => ?), 0x5E => ?;, 0x60 => ?-,
      0x61 => ?/, 0x6B => ?,, 0x6C => ?%, 0x6D => ?_, 0x6E => ?>, 0x6F => ??,
      0x7A => ?:, 0x7B => ?#, 0x7C => ?@, 0x7D => ?', 0x7E => ?=, 0x7F => ?",
      0xF0 => ?0, 0xF1 => ?1, 0xF2 => ?2, 0xF3 => ?3, 0xF4 => ?4,
      0xF5 => ?5, 0xF6 => ?6, 0xF7 => ?7, 0xF8 => ?8, 0xF9 => ?9,
      0xC1 => ?A, 0xC2 => ?B, 0xC3 => ?C, 0xC4 => ?D, 0xC5 => ?E,
      0xC6 => ?F, 0xC7 => ?G, 0xC8 => ?H, 0xC9 => ?I, 0xD1 => ?J,
      0xD2 => ?K, 0xD3 => ?L, 0xD4 => ?M, 0xD5 => ?N, 0xD6 => ?O,
      0xD7 => ?P, 0xD8 => ?Q, 0xD9 => ?R, 0xE2 => ?S, 0xE3 => ?T,
      0xE4 => ?U, 0xE5 => ?V, 0xE6 => ?W, 0xE7 => ?X, 0xE8 => ?Y, 0xE9 => ?Z
    }
    Map.get(table, c, ?\s)
  end
  defp ebcdic_char(_), do: ?\s

  defp extract_pan_token(ascii) do
    raw = String.slice(ascii, 4, 19) |> String.trim()
    :crypto.hash(:sha256, raw) |> Base.encode16(case: :lower)
  end

  defp extract_amount(ascii, offset, len) do
    raw = String.slice(ascii, offset, len) |> String.trim()
    case Integer.parse(raw) do
      {cents, _} -> Decimal.div(Decimal.new(cents), Decimal.new(100))
      :error     -> Decimal.new(0)
    end
  end

  defp extract_currency(_ascii), do: "AED"

  defp extract_date(ascii, offset) do
    str = String.slice(ascii, offset, 4)
    year  = String.slice(str, 0, 2) |> String.to_integer()
    month = String.slice(str, 2, 2) |> String.to_integer()
    Date.new!(2000 + year, month, 1)
  rescue
    _ -> Date.utc_today()
  end
end
