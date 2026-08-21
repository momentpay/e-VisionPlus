defmodule VmuCore.WPS.FileParserTest do
  @moduledoc """
  Config-driven salary-file parsing (Phase W2).

  Pure parsing, so no database — but the cases are chosen from what actually
  goes wrong with payroll files rather than from what is easy to assert.
  """
  use ExUnit.Case, async: true

  alias VmuCore.WPS.FileParser
  alias Decimal, as: D

  describe "delimited files" do
    test "an employer already using our field names needs no mapping" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,1500.00
      E002,PAY-2,2250.50
      """

      assert {:ok, [a, b], []} = FileParser.parse(content, %{})

      assert a.employee_id == "E001"
      assert a.payment_reference == "PAY-1"
      assert D.equal?(a.net_amount, D.new("1500.00"))
      assert b.employee_id == "E002"
    end

    test "import_mapping renames only the columns that differ" do
      content = """
      EmpID,PayRef,NetPay,employee_name
      E001,PAY-1,1500.00,Aisha
      """

      config = %{
        "import_mapping" => %{
          "EmpID" => "employee_id",
          "PayRef" => "payment_reference",
          "NetPay" => "net_amount"
        }
      }

      assert {:ok, [line], []} = FileParser.parse(content, config)

      assert line.employee_id == "E001"
      # Not in the mapping, and passed through unchanged.
      assert line.employee_name == "Aisha"
    end

    test "a custom delimiter and skipped preamble lines" do
      content = """
      # payroll export v2
      # generated 2026-08-01
      employee_id|payment_reference|net_amount
      E001|PAY-1|900.00
      """

      config = %{"delimiter" => "|", "skip_lines" => 2}

      assert {:ok, [line], []} = FileParser.parse(content, config)
      assert line.employee_id == "E001"
      assert D.equal?(line.net_amount, D.new("900.00"))
    end

    test "a headerless file maps by position" do
      content = """
      E001,PAY-1,1500.00
      E002,PAY-2,1600.00
      """

      config = %{
        "has_header" => false,
        "import_mapping" => %{"1" => "employee_id", "2" => "payment_reference", "3" => "net_amount"}
      }

      assert {:ok, [a, b], []} = FileParser.parse(content, config)
      assert a.employee_id == "E001"
      assert b.payment_reference == "PAY-2"
    end

    test "quoted values are unwrapped rather than becoming part of the id" do
      content = """
      employee_id,payment_reference,net_amount
      "E001","PAY-1","1500.00"
      """

      assert {:ok, [line], []} = FileParser.parse(content, %{})
      assert line.employee_id == "E001"
      assert D.equal?(line.net_amount, D.new("1500.00"))
    end

    test "line numbers survive skipped and blank lines" do
      content = """
      # preamble
      employee_id,payment_reference,net_amount
      E001,PAY-1,100.00

      E002,PAY-2,200.00
      """

      config = %{"skip_lines" => 1}

      assert {:ok, [a, b], []} = FileParser.parse(content, config)
      # An operator reading an error report opens the file at this line, so the
      # number has to be the line in the file, not the index among data rows.
      assert a.line_number == 3
      assert b.line_number == 5
    end
  end

  describe "fixed width files" do
    test "fields are sliced by 1-based [start, length] as published layouts state them" do
      content = """
      E001                PAY-0000001         000000150000
      E002                PAY-0000002         000000225050
      """

      config = %{
        "file_format" => "FIXED_WIDTH",
        "amount_format" => "implied_2dp",
        "fixed_width_fields" => %{
          "employee_id" => [1, 20],
          "payment_reference" => [21, 20],
          "net_amount" => [41, 12]
        }
      }

      assert {:ok, [a, b], []} = FileParser.parse(content, config)

      assert a.employee_id == "E001"
      assert a.payment_reference == "PAY-0000001"
      assert D.equal?(a.net_amount, D.new("1500.00"))
      assert D.equal?(b.net_amount, D.new("2250.50"))
    end

    test "fixed width without a configured layout is refused, not guessed" do
      assert {:error, :fixed_width_fields_not_configured} =
               FileParser.parse("anything", %{"file_format" => "FIXED_WIDTH"})
    end
  end

  describe "amount encoding" do
    test "implied_2dp reads minor units — the encoding most likely to be misread" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,123456
      """

      assert {:ok, [line], []} =
               FileParser.parse(content, %{"amount_format" => "implied_2dp"})

      assert D.equal?(line.net_amount, D.new("1234.56"))
    end

    test "the same string reads differently under each encoding — which is why it is configured" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,1234
      """

      {:ok, [as_decimal], []} = FileParser.parse(content, %{"amount_format" => "decimal"})
      {:ok, [as_minor], []} = FileParser.parse(content, %{"amount_format" => "implied_2dp"})

      # 1234.00 vs 12.34 — a hundredfold difference from one config key, and
      # nothing about the string itself says which is right. This is the case
      # that makes inference unacceptable.
      assert D.equal?(as_decimal.net_amount, D.new("1234"))
      assert D.equal?(as_minor.net_amount, D.new("12.34"))
    end

    test "a decimal point under implied_2dp is an error, not a silent reinterpretation" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,1234.56
      """

      assert {:ok, [], [error]} = FileParser.parse(content, %{"amount_format" => "implied_2dp"})

      assert error.field == "net_amount"
      assert error.error =~ "implied_2dp"
    end

    test "thousands separators are tolerated" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,"12,500.75"
      """

      assert {:ok, [line], []} = FileParser.parse(content, %{})
      assert D.equal?(line.net_amount, D.new("12500.75"))
    end
  end

  describe "dates" do
    test "ISO-8601 by default" do
      content = """
      employee_id,payment_reference,net_amount,payment_date
      E001,PAY-1,100.00,2026-07-31
      """

      assert {:ok, [line], []} = FileParser.parse(content, %{})
      assert line.payment_date == ~D[2026-07-31]
    end

    test "a configured strptime format, as the GCC schemes use" do
      content = """
      employee_id,payment_reference,net_amount,payment_date,pay_period_start
      E001,PAY-1,100.00,20260731,20260701
      """

      assert {:ok, [line], []} = FileParser.parse(content, %{"date_format" => "%Y%m%d"})
      assert line.payment_date == ~D[2026-07-31]
      assert line.pay_period_start == ~D[2026-07-01]
    end

    test "a date that does not match the configured format is reported with the format" do
      content = """
      employee_id,payment_reference,net_amount,payment_date
      E001,PAY-1,100.00,31/07/2026
      """

      assert {:ok, [], [error]} = FileParser.parse(content, %{"date_format" => "%Y%m%d"})
      assert error.field == "payment_date"
      assert error.error =~ "%Y%m%d"
    end

    test "an absent optional date is not an error" do
      content = """
      employee_id,payment_reference,net_amount,payment_date
      E001,PAY-1,100.00,
      """

      assert {:ok, [line], []} = FileParser.parse(content, %{})
      assert line.payment_date == nil
    end
  end

  describe "errors accumulate rather than aborting" do
    test "a bad line does not hide the good lines after it" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,100.00
      E002,PAY-2,not-a-number
      E003,PAY-3,300.00
      ,PAY-4,400.00
      E005,PAY-5,500.00
      """

      assert {:ok, lines, errors} = FileParser.parse(content, %{})

      # Three good lines survive two bad ones.
      assert length(lines) == 3
      assert Enum.map(lines, & &1.employee_id) == ["E001", "E003", "E005"]

      assert length(errors) == 2
      # File line numbers, counting the header as line 1 — which is what an
      # operator opening the file in an editor will see.
      assert Enum.map(errors, & &1.line_number) == [3, 5]
    end

    test "an error carries the raw line so an operator can see what arrived" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,oops
      """

      assert {:ok, [], [error]} = FileParser.parse(content, %{})
      assert error.raw == "E001,PAY-1,oops"
      assert error.line_number == 2
    end

    test "a missing required field names the field" do
      content = """
      employee_id,payment_reference,net_amount
      E001,,100.00
      """

      assert {:ok, [], [error]} = FileParser.parse(content, %{})
      assert error.field == "payment_reference"
    end
  end

  describe "net = gross - deductions" do
    test "an inconsistent line is rejected, because it usually means bad column mapping" do
      content = """
      employee_id,payment_reference,gross_amount,deduction_amount,net_amount
      E001,PAY-1,5000.00,500.00,9999.00
      """

      assert {:ok, [], [error]} = FileParser.parse(content, %{})
      assert error.error =~ "column-mapping"
    end

    test "a consistent line passes" do
      content = """
      employee_id,payment_reference,gross_amount,deduction_amount,net_amount
      E001,PAY-1,5000.00,500.00,4500.00
      """

      assert {:ok, [line], []} = FileParser.parse(content, %{})
      assert D.equal?(line.net_amount, D.new("4500.00"))
    end

    test "the check is skippable for employers whose files legitimately disagree" do
      content = """
      employee_id,payment_reference,gross_amount,deduction_amount,net_amount
      E001,PAY-1,5000.00,500.00,9999.00
      """

      config = %{"require_net_equals_gross_minus_deductions" => false}

      assert {:ok, [_line], []} = FileParser.parse(content, config)
    end

    test "gross absent means the check cannot run, and does not fail the line" do
      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-1,4500.00
      """

      assert {:ok, [_line], []} = FileParser.parse(content, %{})
    end
  end

  describe "refusals" do
    test "an unsupported file format is refused by name" do
      assert {:error, {:unsupported_file_format, "XML"}} =
               FileParser.parse("x", %{"file_format" => "XML"})
    end

    test "an empty file parses to nothing rather than raising" do
      assert {:ok, [], []} = FileParser.parse("", %{})
    end

    test "a header-only file yields no lines" do
      assert {:ok, [], []} = FileParser.parse("employee_id,payment_reference,net_amount\n", %{})
    end
  end
end
