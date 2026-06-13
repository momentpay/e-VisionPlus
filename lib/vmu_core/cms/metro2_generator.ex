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
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, Shared.Customer}
  alias VmuCore.CDM.BureauAdapter

  @bureau_adapter Application.compile_env(:vmu_core, [:cdm, :bureau_adapter], VmuCore.CDM.MockBureauAdapter)

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
       Enum.map(accounts, &build_base_segment(&1, report_date))] ++
      [trailer_record(length(accounts))]
      |> Enum.join("\n")

    File.write!(file_path, content)
    Logger.info("[Metro2] File written: #{file_path}")

    case @bureau_adapter.submit_metro2_file(file_path) do
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
    balance     = bucket.retail_balance |> decimal_to_minor_units() |> pad_decimal(9)
    past_due    = bucket.unpaid_fees   |> decimal_to_minor_units() |> pad_decimal(9)
    credit_limit = acc.credit_limit    |> decimal_to_minor_units() |> pad_decimal(9)

    account_status = metro2_account_status(acc.account_status, acc.delinquency_bucket)
    date_reported  = format_date(report_date)
    date_opened    = format_date(acc.inserted_at |> NaiveDateTime.to_date())

    [
      @segment_length,
      "DA",
      date_reported,
      pad_right(acc.account_id |> String.slice(0, 12), 12),
      @portfolio_type,
      @account_type,
      "097",       # terms duration — revolving
      "M",         # monthly
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
      "        ",   # date of first delinquency (blank unless DPD > 0)
      "        ",   # date closed
      "        ",   # date of last payment
      account_status,
      pad_right(cust.customer_id |> String.slice(0, 10), 10)
    ]
    |> Enum.join()
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
