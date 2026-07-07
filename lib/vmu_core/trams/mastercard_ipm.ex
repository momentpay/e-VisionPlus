defmodule VmuCore.TRAMS.MastercardIpm do
  @moduledoc """
  Mastercard IPM (Interchange Posting and Management) file parser.

  IPM is a binary fixed-width format carrying clearing records from Mastercard.
  Each file contains a header record (1644 bytes) and data records (1644 bytes each).

  Record structure (DE positions per Mastercard CIS specification):
    Bytes 1-4    : Message Type Indicator (BCD)
    Bytes 5-20   : Primary Bitmap (binary)
    Bytes 21+    : Data elements (variable per bitmap)

  This parser extracts:
    - MTI 1240 (Financial presentment) — the core clearing record
    - DE 2  (PAN), DE 4 (Amount), DE 12/13 (Transaction date/time)
    - DE 22 (POS Entry Mode), DE 24 (Function Code)
    - DE 38 (Auth Code), DE 37 (RRN), DE 41/42 (Terminal/Merchant IDs)
    - DE 48 (Additional data), DE 49 (Currency)

  Uses a Broadway pipeline for high-volume production file processing.
  For testing/seeding, use parse_file/1 directly.
  """

  require Logger
  alias VmuCore.TRAMS.ClearingRecord
  alias VmuCore.{Repo, CMS.Account, Shared.CurrencyCodes}
  import Ecto.Query
  import Bitwise

  @record_length 1644
  @header_mti    "0100"
  @presentment_mti "1240"

  @doc """
  Parse an IPM file and return a list of clearing record attrs.
  Each record is suitable for insertion into trams_clearing_records.
  """
  def parse_file(file_path) do
    Logger.info("[TRAMS/IPM] Parsing file: #{file_path}")

    case File.read(file_path) do
      {:ok, binary} ->
        records = parse_records(binary, file_path)
        Logger.info("[TRAMS/IPM] Parsed #{length(records)} records from #{Path.basename(file_path)}")
        {:ok, records}

      {:error, reason} ->
        Logger.error("[TRAMS/IPM] Failed to read file #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Parse a single 1644-byte record binary. Returns {:ok, attrs} or {:error, reason}.
  Called from IpmPipeline processors.
  """
  def parse_record(binary) do
    try do
      attrs = extract_fields(binary, "pipeline")
      if attrs, do: {:ok, attrs}, else: {:error, :parse_failed}
    rescue
      e -> {:error, e}
    end
  end

  @doc """
  Process an IPM file end-to-end: parse → match → insert clearing records.
  Returns {:ok, %{inserted: n, matched: n, unmatched: n}}.
  """
  def process_file(file_path) do
    with {:ok, records} <- parse_file(file_path) do
      results = Enum.map(records, &insert_and_match/1)

      counts = Enum.reduce(results, %{inserted: 0, matched: 0, unmatched: 0}, fn
        {:ok, :matched},   acc -> %{acc | inserted: acc.inserted + 1, matched: acc.matched + 1}
        {:ok, :unmatched}, acc -> %{acc | inserted: acc.inserted + 1, unmatched: acc.unmatched + 1}
        {:error, _},       acc -> acc
      end)

      {:ok, counts}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — binary parsing with full BCD bitmap decoder (G6)
  # ---------------------------------------------------------------------------

  # DE length definitions for MTI 1240 per Mastercard CIS spec.
  # Format: {de_no, type, length}
  #   type :fixed_bcd  => BCD-encoded, fixed byte length
  #   type :llvar_bcd  => 1-byte BCD length prefix then BCD data
  #   type :fixed_ascii => ASCII, fixed byte count
  #   type :lllvar_ascii => 3-digit ASCII length prefix then ASCII data
  @de_specs %{
    2  => {:llvar_bcd,    19},   # PAN (max 19 BCD digits = 10 bytes)
    4  => {:fixed_bcd,     6},   # Amount, transaction (12 BCD digits)
    11 => {:fixed_bcd,     3},   # STAN (6 BCD digits)
    12 => {:fixed_bcd,     3},   # Time, local (HHMMSS, 6 BCD digits)
    13 => {:fixed_bcd,     2},   # Date, local (MMDD, 4 BCD digits)
    22 => {:fixed_bcd,     2},   # POS Entry Mode (3 BCD digits, right-padded)
    24 => {:fixed_bcd,     2},   # Function Code (3 BCD digits)
    37 => {:fixed_ascii,  12},   # Retrieval Reference Number
    38 => {:fixed_ascii,   6},   # Authorization ID Response
    41 => {:fixed_ascii,   8},   # Card Acceptor Terminal ID
    42 => {:fixed_ascii,  15},   # Card Acceptor ID Code (Merchant ID)
    43 => {:fixed_ascii,  40},   # Card Acceptor Name/Location
    48 => {:lllvar_ascii, 999},  # Additional Data, Private Use
    49 => {:fixed_bcd,     2},   # Currency Code (3 BCD digits)
    63 => {:lllvar_ascii, 999}   # Private use / MCC
  }

  defp parse_records(binary, file_name) do
    binary
    |> split_records()
    |> Enum.filter(&presentment_record?/1)
    |> Enum.map(&extract_fields(&1, file_name))
    |> Enum.reject(&is_nil/1)
  end

  defp split_records(binary) do
    total = byte_size(binary)
    count = div(total, @record_length)
    for i <- 0..(count - 1), do: binary_part(binary, i * @record_length, @record_length)
  end

  defp presentment_record?(<<mti::binary-size(4), _rest::binary>>) do
    mti == @presentment_mti
  rescue
    _ -> false
  end
  defp presentment_record?(_), do: false

  defp extract_fields(record, file_name) do
    try do
      <<_mti::binary-size(4), bitmap::binary-size(16), data::binary>> = record

      present_des = parse_bitmap(bitmap)
      des = decode_data_elements(data, present_des)

      pan_raw = Map.get(des, 2, <<>>)
      pan_token =
        :crypto.hash(:sha256, pan_raw)
        |> Base.encode16(case: :lower)

      amount = bcd_to_decimal(Map.get(des, 4, <<0, 0, 0, 0, 0, 0>>), 2)

      currency = bcd_bytes_to_string(Map.get(des, 49, <<0, 0>>)) |> iso4217_numeric_to_alpha()

      date_bcd = Map.get(des, 13, <<>>)
      txn_date = parse_mmdd_date(date_bcd)

      rrn       = Map.get(des, 37, "") |> String.trim()
      auth_code = Map.get(des, 38, "") |> String.trim()
      mcc       = extract_mcc_from_des(des)

      %{
        network:          "MC",
        file_name:        Path.basename(file_name),
        record_type:      "1240",
        pan_token:        pan_token,
        amount:           amount,
        currency:         currency,
        transaction_date: txn_date,
        rrn:              rrn,
        auth_code:        auth_code,
        mcc:              mcc,
        merchant_id:      Map.get(des, 42, "") |> String.trim(),
        terminal_id:      Map.get(des, 41, "") |> String.trim(),
        match_status:     "UNMATCHED"
      }
    rescue
      e ->
        Logger.warning("[TRAMS/IPM] Failed to extract fields: #{inspect(e)}")
        nil
    end
  end

  # Parse 128-bit primary + secondary bitmap → list of present DE numbers
  defp parse_bitmap(<<primary::binary-size(8), secondary::binary-size(8)>>) do
    primary_des  = bitmap_bits(primary, 1)
    secondary_present = Enum.member?(primary_des, 1)

    secondary_des =
      if secondary_present,
        do: bitmap_bits(secondary, 65),
        else: []

    primary_des ++ secondary_des
  end
  defp parse_bitmap(_), do: []

  defp bitmap_bits(bitmap_bytes, offset) do
    bitmap_bytes
    |> :binary.bin_to_list()
    |> Enum.with_index()
    |> Enum.flat_map(fn {byte, byte_idx} ->
      for bit_idx <- 0..7, band(byte, bsr(0x80, bit_idx)) != 0 do
        offset + byte_idx * 8 + bit_idx
      end
    end)
  end

  # Walk data elements in DE number order, extracting each present DE
  defp decode_data_elements(data, present_des) do
    sortable = Enum.sort(present_des)
    {des, _} = Enum.reduce(sortable, {%{}, data}, fn de_no, {acc, remaining} ->
      case Map.get(@de_specs, de_no) do
        nil ->
          {acc, remaining}

        {:fixed_bcd, byte_len} ->
          if byte_size(remaining) >= byte_len do
            <<value::binary-size(byte_len), rest::binary>> = remaining
            {Map.put(acc, de_no, value), rest}
          else
            {acc, <<>>}
          end

        {:llvar_bcd, _max} ->
          if byte_size(remaining) >= 1 do
            <<len_byte, rest::binary>> = remaining
            # BCD length byte: high nibble × 10 + low nibble
            len = bcd_byte_to_int(len_byte)
            byte_count = div(len + 1, 2)
            if byte_size(rest) >= byte_count do
              <<value::binary-size(byte_count), rest2::binary>> = rest
              {Map.put(acc, de_no, value), rest2}
            else
              {acc, <<>>}
            end
          else
            {acc, <<>>}
          end

        {:fixed_ascii, byte_len} ->
          if byte_size(remaining) >= byte_len do
            <<value::binary-size(byte_len), rest::binary>> = remaining
            {Map.put(acc, de_no, value), rest}
          else
            {acc, <<>>}
          end

        {:lllvar_ascii, _max} ->
          if byte_size(remaining) >= 3 do
            <<len_str::binary-size(3), rest::binary>> = remaining
            len = String.to_integer(len_str)
            if byte_size(rest) >= len do
              <<value::binary-size(len), rest2::binary>> = rest
              {Map.put(acc, de_no, value), rest2}
            else
              {acc, <<>>}
            end
          else
            {acc, <<>>}
          end
      end
    end)
    des
  end

  # BCD utilities
  defp bcd_byte_to_int(byte), do: div(byte, 16) * 10 + rem(byte, 16)

  defp bcd_to_decimal(bcd_bytes, decimal_places) do
    digits =
      bcd_bytes
      |> :binary.bin_to_list()
      |> Enum.flat_map(fn b -> [div(b, 16), rem(b, 16)] end)
      |> Enum.join()
      |> String.to_integer()

    Decimal.div(Decimal.new(digits), Decimal.new(round(:math.pow(10, decimal_places))))
  rescue
    _ -> Decimal.new(0)
  end

  defp bcd_bytes_to_string(bytes) do
    bytes
    |> :binary.bin_to_list()
    |> Enum.flat_map(fn b -> [Integer.to_string(div(b, 16)), Integer.to_string(rem(b, 16))] end)
    |> Enum.join()
  end

  # Consolidated into Shared.CurrencyCodes (2026-07-07) — this stub only
  # covered 4 currencies and silently defaulted anything else to "AED",
  # which would have mislabeled the currency on any non-AED/USD/EUR/GBP
  # clearing record. Falls back to "AED" only when the numeric code truly
  # isn't in the shared table, preserving this function's prior behavior
  # for the currencies it never covered.
  defp iso4217_numeric_to_alpha(code), do: CurrencyCodes.to_alpha(code) || "AED"

  defp parse_mmdd_date(<<>>) do
    Date.utc_today()
  end
  defp parse_mmdd_date(<<b1, b2>>) do
    month = bcd_byte_to_int(b1)
    day   = bcd_byte_to_int(b2)
    today = Date.utc_today()
    year  = if month > today.month, do: today.year - 1, else: today.year
    case Date.new(year, month, day) do
      {:ok, date} -> date
      _           -> Date.utc_today()
    end
  rescue
    _ -> Date.utc_today()
  end
  defp parse_mmdd_date(_), do: Date.utc_today()

  defp extract_mcc_from_des(des) do
    # MCC may appear in DE 26 (not defined here yet) or DE 63 private use
    # Fall back to "0000" when not parseable
    case Map.get(des, 26) do
      <<b1, b2>> -> bcd_bytes_to_string(<<b1, b2>>) |> String.slice(0, 4)
      _          -> "0000"
    end
  end

  defp insert_and_match(attrs) do
    account_id = resolve_account(attrs.pan_token)
    attrs = Map.put(attrs, :account_id, account_id)

    case Repo.insert(ClearingRecord.changeset(%ClearingRecord{}, attrs)) do
      {:ok, rec} ->
        if rec.account_id do
          VmuCore.ITS.FeeClaimProcessor.create_claim(rec)
        end
        match_result = match_to_authorization(rec)
        {:ok, match_result}

      {:error, cs} ->
        Logger.error("[TRAMS/IPM] Insert failed: #{inspect(cs.errors)}")
        {:error, cs}
    end
  end

  defp resolve_account(pan_token) do
    Repo.one(from a in Account, where: a.pan_token == ^pan_token, select: a.account_id)
  end

  defp match_to_authorization(%VmuCore.TRAMS.ClearingRecord{rrn: nil}), do: :unmatched
  defp match_to_authorization(_rec), do: :unmatched
end
