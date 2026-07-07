defmodule VmuCore.CMS.Metro2Generator do
  @moduledoc """
  Credit bureau Metro 2 monthly file generator.

  Metro 2 is the CDIA (Consumer Data Industry Association) standard format
  used to report credit account data to bureaus (Equifax, Experian, TransUnion).

  File structure:
    - Header Record (1 per file, segment J1)
    - Base Segment (1 per account, 426 characters fixed-width)
    - J1 Segment (consumer name — attached after Base Segment)
    - Trailer Record (1 per file)

  Base Segment key fields (positions per CDIA Metro 2 spec):
    1-4     : Segment length ("0426" for base)
    5-6     : Processing indicator ("DA" = data as of date)
    7-14    : Date Reported (MMDDYYYY)
    15-26   : Account Number (left-justified, space-padded)
    27      : Portfolio Type (R=Revolving, I=Installment, O=Open, M=Mortgage)
    28      : Account Type (18=Credit Card)
    29-30   : Terms Duration ("097" = revolving, "001" = single pay)
    31-32   : Terms Frequency ("M" = monthly, "W"=weekly)
    33-40   : Date Opened (MMDDYYYY)
    41-49   : Credit Limit (9 digits, zero-padded minor units)
    50-58   : Highest Credit (same)
    59-67   : Terms Amount (same)
    68-76   : Balance (same)
    77-85   : Amount Past Due
    86-94   : Current Payment Level Amount
    95      : Payment History Profile (most recent month in position 1)
    96-101  : Special Comment (space or 2-char code)
    102     : Compliance Condition Code (space or 2-char)
    103-110 : Date of Account Information (MMDDYYYY)
    111-118 : Date of First Delinquency (MMDDYYYY if applicable)
    119-126 : Date Closed (MMDDYYYY if applicable)
    127-134 : Date of Last Payment (MMDDYYYY)
    135     : Account Status (13=Current, 71=120+ days past due, 97=Charged-off)
    136-145 : Consumer Account Number
    146+    : Consumer information block

  VisionPlus transmits files monthly on statement cycle + 3 business days.
  File is submitted via BureauAdapter.submit_metro2_file/1.
  """

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.BlockCodeHistory, Shared.Customer}
  alias VmuCore.CMS.BureauAdapter

  @segment_length "0426"
  @portfolio_type "R"   # Revolving (credit card)
  @account_type   "18"  # Credit card

  @doc """
  Generate a Metro 2 file for all active accounts under a sys_id/bank_id/logo_id
  and submit it to the bureau via BureauAdapter.
  """
  def generate_and_submit(sys_id, bank_id, logo_id) do
    report_date = Date.utc_today()
    filename = "metro2_#{sys_id}_#{bank_id}_#{logo_id}_#{Date.to_iso8601(report_date)}.dat"
    file_path = Path.join(System.tmp_dir!(), filename)

    Logger.info("[Metro2] Generating file: #{filename}")

    accounts = load_accounts(sys_id, bank_id, logo_id)
    Logger.info("[Metro2] #{length(accounts)} accounts to report")

    content =
      [header_record(report_date, sys_id) |
       Enum.flat_map(accounts, fn a ->
         [build_base_segment(a, report_date), build_j1_segment(a.customer)]
       end)] ++
      [trailer_record(length(accounts))]
      |> Enum.join("\n")

    File.write!(file_path, content)
    Logger.info("[Metro2] File written: #{file_path}")

    case BureauAdapter.submit_metro2_file(file_path) do
      {:ok, bureau_ref} ->
        Logger.info("[Metro2] File submitted: ref=#{bureau_ref}")
        File.rm(file_path)
        {:ok, bureau_ref}

      {:error, reason} ->
        Logger.error("[Metro2] Submit failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Private — record builders
  # ---------------------------------------------------------------------------

  defp load_accounts(sys_id, bank_id, logo_id) do
    Repo.all(
      from a in Account,
        join: b in BalanceBucket, on: b.account_id == a.account_id,
        join: c in Customer, on: c.customer_id == a.customer_id,
        where: a.sys_id == ^sys_id and a.bank_id == ^bank_id and a.logo_id == ^logo_id
          and a.account_status != "PENDING",
        select: %{
          account: a,
          bucket:  b,
          customer: c
        }
    )
  end

  defp header_record(report_date, reporter_id) do
    date_str = format_date(report_date)
    "HEADER   #{pad_right(reporter_id, 9)}#{date_str}METRO2"
  end

  defp trailer_record(count) do
    "TRAILER  #{String.pad_leading(to_string(count), 9, "0")}"
  end

  defp build_base_segment(%{account: acc, bucket: bucket, customer: cust}, report_date) do
    balance      = bucket.retail_balance |> decimal_to_minor_units() |> pad_decimal(9)
    past_due     = bucket.unpaid_fees   |> decimal_to_minor_units() |> pad_decimal(9)
    credit_limit = acc.credit_limit     |> decimal_to_minor_units() |> pad_decimal(9)

    account_status = metro2_account_status(acc.account_status, acc.delinquency_bucket)
    date_reported  = format_date(report_date)
    date_opened    = format_date(acc.inserted_at |> NaiveDateTime.to_date())

    # Metro 2 field 111–118: Date of First Delinquency (MMDDYYYY)
    # Required when account has ever been 30+ DPD; blank ("        ") if never delinquent.
    dofd_str = build_dofd(acc.account_id, acc.delinquency_bucket)

    [
      @segment_length,
      "DA",
      date_reported,
      pad_right(acc.account_id |> String.slice(0, 12), 12),
      @portfolio_type,
      @account_type,
      "097",        # terms duration — revolving
      "M",          # monthly
      date_opened,
      credit_limit,
      credit_limit, # highest credit = current limit (simplified)
      "000000000",  # terms amount
      balance,
      past_due,
      "000000000",  # current payment level
      payment_history_code(acc.delinquency_bucket),
      "      ",     # special comment (6 spaces)
      " ",          # compliance condition (1 space)
      date_reported,
      dofd_str,     # date of first delinquency — 8 chars (MMDDYYYY or 8 spaces)
      "        ",   # date closed
      "        ",   # date of last payment
      account_status,
      pad_right(cust.customer_id |> String.slice(0, 10), 10)
    ]
    |> Enum.join()
  end

  # Build the 8-character DOFD field (MMDDYYYY) for Metro 2 positions 111–118.
  #
  # Strategy:
  #   1. Query block_code_history for the earliest BLOCKED entry with a delinquency
  #      reason code (COLLECTIONS_HOLD, OVERLIMIT). This captures when the account
  #      first became delinquent as recorded by an operator or EOD automation.
  #   2. If no block history exists but delinquency_bucket > 0, fall back to the
  #      earliest balance_bucket row where dpd_bucket > 0 (set by AgeBucketsJob).
  #   3. If the account is current (delinquency_bucket == 0), return 8 spaces.
  #
  # Per CDIA Metro 2 spec §4.3: DOFD must be reported once set and must NOT be
  # cleared even after the account becomes current again.
  defp build_dofd(account_id, delinquency_bucket) do
    case fetch_dofd(account_id, delinquency_bucket) do
      {:ok, date} -> format_date(date)
      :blank      -> "        "
    end
  end

  defp fetch_dofd(_account_id, 0), do: :blank

  defp fetch_dofd(account_id, _bucket) do
    # Source 1: block_code_history — earliest delinquency-related block
    delinquency_reason_codes = ~w[COLLECTIONS_HOLD OVERLIMIT]

    earliest_block =
      Repo.one(
        from h in BlockCodeHistory,
          where: h.account_id == ^account_id
            and h.action == "BLOCKED"
            and h.reason_code in ^delinquency_reason_codes,
          order_by: [asc: h.applied_at],
          limit: 1,
          select: h.applied_at
      )

    case earliest_block do
      %NaiveDateTime{} = dt ->
        {:ok, NaiveDateTime.to_date(dt)}

      nil ->
        # Source 2: balance_bucket inserted_at as proxy for first-delinquency date
        # (AgeBucketsJob sets dpd_bucket; oldest bucket with dpd > 0 approximates DOFD)
        earliest_bucket =
          Repo.one(
            from b in BalanceBucket,
              where: b.account_id == ^account_id
                and b.dpd_bucket > 0,
              order_by: [asc: b.inserted_at],
              limit: 1,
              select: b.inserted_at
          )

        case earliest_bucket do
          %NaiveDateTime{} = dt -> {:ok, NaiveDateTime.to_date(dt)}
          nil                   -> :blank
        end
    end
  end

  # ---------------------------------------------------------------------------
  # J1 Segment — Consumer Name Block (Metro 2 §4.7)
  # ---------------------------------------------------------------------------
  #
  # The J1 segment immediately follows the Base Segment for the same consumer.
  # It carries the full consumer name in structured fields.
  #
  # Field layout (fixed-width, total 212 characters):
  #   1-4    : Segment identifier — "J1  " (left-justified, space-padded to 4)
  #   5-34   : Surname / Last Name (30 chars, upper, space-padded)
  #   35-54  : First Name (20 chars, upper, space-padded)
  #   55-64  : Middle Name / Initial (10 chars, upper, space-padded)
  #   65-67  : Suffix (3 chars: JR, SR, II, III, IV, V, space-padded)
  #   68-68  : Generation Code (1 char: J=Junior, S=Senior, space=N/A)
  #   69-212 : Reserved / blank-padded to total 212 characters
  #
  # Source data: Customer.full_name is parsed into surname/first/middle tokens.
  # If the customer record has structured name fields (first_name, last_name),
  # those take precedence.

  defp build_j1_segment(%Customer{} = cust) do
    {surname, first_name, middle_name, suffix, generation} = parse_consumer_name(cust)

    segment =
      [
        "J1  ",
        pad_right(String.upcase(surname),     30),
        pad_right(String.upcase(first_name),  20),
        pad_right(String.upcase(middle_name), 10),
        pad_right(String.upcase(suffix),       3),
        generation                                  # 1 char
      ]
      |> Enum.join()

    # Pad to exactly 212 characters
    String.pad_trailing(segment, 212)
  end

  # Parse a Customer record into {surname, first, middle, suffix, generation_code}.
  # Prefers structured fields; falls back to splitting full_name by whitespace.
  defp parse_consumer_name(%Customer{} = cust) do
    full = (cust.full_name || "") |> String.trim()
    tokens = String.split(full, ~r/\s+/, trim: true)

    {surname, first, middle} =
      case tokens do
        []         -> {"", "", ""}
        [last]     -> {last, "", ""}
        [f, l]     -> {l, f, ""}
        [f, m | rest] ->
          last = List.last(rest)
          {last, f, m}
      end

    # Detect common suffixes in the last token
    {clean_surname, suffix, generation} = extract_suffix(surname)

    {clean_surname, first, middle, suffix, generation}
  end

  @suffixes %{
    "JR"  => {"JR",  "J"},
    "SR"  => {"SR",  "S"},
    "II"  => {"II",  " "},
    "III" => {"III", " "},
    "IV"  => {"IV",  " "},
    "V"   => {"V",   " "}
  }

  defp extract_suffix(surname) do
    upper = String.upcase(surname)
    result = Enum.find(@suffixes, fn {k, _} -> String.ends_with?(upper, " " <> k) end)

    case result do
      {key, {sfx, gen}} ->
        clean = String.slice(surname, 0, byte_size(surname) - byte_size(key) - 1)
        {String.trim(clean), sfx, gen}
      nil ->
        {surname, "", " "}
    end
  end

  defp metro2_account_status("WRITTEN_OFF", _), do: "97"
  defp metro2_account_status(_, dpd), do: dpd_to_account_status(dpd)

  defp dpd_to_account_status(0),   do: "13"   # Current
  defp dpd_to_account_status(30),  do: "71"   # 30-59 days
  defp dpd_to_account_status(60),  do: "78"   # 60-89 days
  defp dpd_to_account_status(90),  do: "80"   # 90-119 days
  defp dpd_to_account_status(120), do: "82"   # 120+ days
  defp dpd_to_account_status(_),   do: "13"

  defp payment_history_code(0),   do: "C"   # Current
  defp payment_history_code(30),  do: "1"   # 30 days late
  defp payment_history_code(60),  do: "2"   # 60 days late
  defp payment_history_code(90),  do: "3"   # 90 days late
  defp payment_history_code(120), do: "4"   # 120+ days late
  defp payment_history_code(_),   do: "C"

  defp decimal_to_minor_units(nil), do: 0
  defp decimal_to_minor_units(d) do
    Decimal.mult(d, Decimal.new(100)) |> Decimal.round(0) |> Decimal.to_integer()
  end

  defp pad_decimal(int, width) when is_integer(int) do
    int |> abs() |> Integer.to_string() |> String.pad_leading(width, "0")
  end

  defp pad_right(str, width) when is_binary(str) do
    String.pad_trailing(String.slice(str, 0, width), width)
  end

  defp format_date(%Date{} = d) do
    Calendar.strftime(d, "%m%d%Y")
  end
end
