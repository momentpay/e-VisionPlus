defmodule VmuCore.WPS.IngestionTest do
  @moduledoc """
  Salary file ingestion (Phase W2).

  Real Postgres — the duplicate-file guard and the payment-reference uniqueness
  guarantee are both database constraints, and they are the two things here
  whose failure costs real money.
  """
  use VmuCore.DataCase, async: false

  alias VmuCore.Shared.{BankParameter, ModuleConfigEngine, ModuleConfigWriter, SysParameter}
  alias VmuCore.WPS.{Ingestion, Roster, WpsFile}
  alias Decimal, as: D

  @csv """
  employee_id,payment_reference,gross_amount,deduction_amount,net_amount,payment_date
  E001,PAY-001,5000.00,500.00,4500.00,2026-07-31
  E002,PAY-002,3000.00,0.00,3000.00,2026-07-31
  E003,PAY-003,7000.00,700.00,6300.00,2026-07-31
  """

  defp institution do
    n = System.unique_integer([:positive])
    sys_id = "G#{100 + rem(n, 900)}"
    bank_id = "H#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "t"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "t"})
    |> Repo.insert!()

    {sys_id, bank_id}
  end

  defp employer_fixture(layout \\ %{}) do
    {sys_id, bank_id} = institution()
    n = System.unique_integer([:positive])
    code = "EMP#{n}"

    {:ok, employer} =
      Roster.onboard_employer(%{
        sys_id: sys_id,
        bank_id: bank_id,
        employer_code: code,
        employer_name: "Gulf Contracting #{n}"
      })

    :ok = put_layout(sys_id, bank_id, code, layout)

    employer
  end

  defp put_layout(sys_id, bank_id, employer_code, layout) do
    {:ok, existing} = ModuleConfigEngine.get("wps", "employer_config", sys_id, bank_id)
    put_config(sys_id, bank_id, "employer_config", Map.put(existing || %{}, employer_code, layout))
  end

  defp put_config(sys_id, bank_id, key, value) do
    {:ok, _} =
      ModuleConfigWriter.put(
        "wps",
        key,
        value,
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id},
        %{username: "test", role: "sysadmin"}
      )

    ModuleConfigEngine.refresh_all()
    :ok
  end

  describe "ingest/4" do
    test "parses a file and stores its lines" do
      employer = employer_fixture()

      assert {:ok, file, summary} =
               Ingestion.ingest(employer.employer_id, "july.csv", @csv, uploaded_by: "ops1")

      assert summary.parsed == 3
      assert summary.errors == 0
      assert file.status == "PARSED"
      assert file.parsed_count == 3
      assert D.equal?(file.total_net_amount, D.new("13800.00"))
      assert file.uploaded_by == "ops1"

      credits = Ingestion.list_credits(file.wps_file_id)
      assert length(credits) == 3
      assert Enum.map(credits, & &1.employee_id) == ["E001", "E002", "E003"]
      assert Enum.all?(credits, &(&1.status == "PARSED"))
    end

    test "an employer with no layout configured is refused, not guessed at" do
      {sys_id, bank_id} = institution()

      {:ok, employer} =
        Roster.onboard_employer(%{
          sys_id: sys_id, bank_id: bank_id,
          employer_code: "UNCONFIGURED", employer_name: "No Layout Co"
        })

      # Guessing a layout is how amounts end up in the wrong column, so absence
      # of configuration is a refusal rather than a default.
      assert {:error, :employer_not_configured} =
               Ingestion.ingest(employer.employer_id, "x.csv", @csv)
    end

    test "the layout used is snapshotted onto the file, not referenced" do
      employer = employer_fixture(%{"delimiter" => ",", "currency" => "AED"})

      {:ok, file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      assert file.layout_snapshot["currency"] == "AED"

      # Change the live config afterwards; the file still records how it *was*
      # parsed, which is what makes an investigation months later meaningful.
      :ok = put_layout(employer.sys_id, employer.bank_id, employer.employer_code, %{"currency" => "SAR"})

      reloaded = Ingestion.get_file(file.wps_file_id)
      assert reloaded.layout_snapshot["currency"] == "AED"
    end

    test "a partially-parseable file is ingested with its failures recorded" do
      employer = employer_fixture()

      content = """
      employee_id,payment_reference,net_amount
      E001,PAY-A,100.00
      E002,PAY-B,not-a-number
      E003,PAY-C,300.00
      """

      assert {:ok, file, summary} = Ingestion.ingest(employer.employer_id, "mixed.csv", content)

      # 2 of 3 good lines are kept. Refusing the file would discard two correct
      # payment instructions over someone else's typo.
      assert summary.parsed == 2
      assert summary.errors == 1
      assert file.error_count == 1

      [error] = Ingestion.parse_errors(file)
      assert error["line_number"] == 3
      assert error["field"] == "net_amount"
    end
  end

  describe "duplicate files" do
    test "the same content is refused by default" do
      employer = employer_fixture()

      assert {:ok, _file, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      # Same bytes, different filename — a re-sent transmission. The guard is on
      # content, because the failure it prevents is paying the batch twice.
      assert {:error, :duplicate_file} =
               Ingestion.ingest(employer.employer_id, "july-resend.csv", @csv)
    end

    test "a different employer may send identical content" do
      a = employer_fixture()
      b = employer_fixture()

      assert {:ok, _, _} = Ingestion.ingest(a.employer_id, "july.csv", @csv)
      # Scoped per employer: two companies can legitimately have identical files.
      assert {:ok, _, _} = Ingestion.ingest(b.employer_id, "july.csv", @csv)
    end

    test "the warn policy ingests the duplicate instead of refusing it" do
      employer = employer_fixture()

      :ok = put_config(employer.sys_id, employer.bank_id, "duplicate_file_policy", "warn")

      assert {:ok, _, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      # The second ingest fails on payment_reference uniqueness rather than the
      # hash — which is the deeper guarantee, and the one that actually stops a
      # double payment.
      assert {:error, {:duplicate_payment_reference, "PAY-001", 2}} =
               Ingestion.ingest(employer.employer_id, "july-again.csv", @csv)
    end
  end

  describe "payment reference uniqueness" do
    test "a corrected resubmission repeating a reference is refused" do
      employer = employer_fixture()

      assert {:ok, _, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      # Genuinely different content — a corrected amount — so the hash guard
      # does not fire. The payment reference is what stops PAY-001 being paid a
      # second time.
      corrected = String.replace(@csv, "4500.00", "4600.00") |> String.replace("5000.00", "5100.00")

      assert {:error, {:duplicate_payment_reference, "PAY-001", _line}} =
               Ingestion.ingest(employer.employer_id, "july-corrected.csv", corrected)
    end

    test "nothing is stored when a line is rejected mid-file" do
      employer = employer_fixture()

      {:ok, first, _} = Ingestion.ingest(employer.employer_id, "july.csv", @csv)

      corrected = String.replace(@csv, "3000.00,2026", "3100.00,2026")
      {:error, _} = Ingestion.ingest(employer.employer_id, "july-corrected.csv", corrected)

      # The whole ingest is one transaction: a half-loaded file is worse than
      # no file, because an operator cannot tell which half is live.
      assert length(Ingestion.list_files(employer.employer_id)) == 1
      assert hd(Ingestion.list_files(employer.employer_id)).wps_file_id == first.wps_file_id
    end
  end

  describe "layout configuration drives parsing" do
    test "a fixed-width file with implied minor units" do
      employer =
        employer_fixture(%{
          "file_format" => "FIXED_WIDTH",
          "amount_format" => "implied_2dp",
          "date_format" => "%Y%m%d",
          "fixed_width_fields" => %{
            "employee_id" => [1, 10],
            "payment_reference" => [11, 15],
            "net_amount" => [26, 12],
            "payment_date" => [38, 8]
          }
        })

      content = """
      E001      PAY-001        00000045000020260731
      E002      PAY-002        00000030000020260731
      """

      assert {:ok, file, summary} = Ingestion.ingest(employer.employer_id, "july.txt", content)

      assert summary.parsed == 2
      assert file.file_format == "FIXED_WIDTH"

      [a, b] = Ingestion.list_credits(file.wps_file_id)
      assert D.equal?(a.net_amount, D.new("4500.00"))
      assert D.equal?(b.net_amount, D.new("3000.00"))
      assert a.payment_date == ~D[2026-07-31]
    end

    test "an employer's own column names are mapped without changing the file" do
      employer =
        employer_fixture(%{
          "import_mapping" => %{
            "StaffNo" => "employee_id",
            "TxnRef" => "payment_reference",
            "Salary" => "net_amount"
          }
        })

      content = """
      StaffNo,TxnRef,Salary
      X-9,REF-9,880.25
      """

      assert {:ok, file, summary} = Ingestion.ingest(employer.employer_id, "custom.csv", content)
      assert summary.parsed == 1

      [credit] = Ingestion.list_credits(file.wps_file_id)
      assert credit.employee_id == "X-9"
      assert D.equal?(credit.net_amount, D.new("880.25"))
    end
  end

  describe "hashing" do
    test "identical bytes hash identically, different bytes do not" do
      assert WpsFile.hash("abc") == WpsFile.hash("abc")
      refute WpsFile.hash("abc") == WpsFile.hash("abd")
      assert String.length(WpsFile.hash("abc")) == 64
    end
  end
end
