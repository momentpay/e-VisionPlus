defmodule VmuCore.COL.AgencyDeskFieldMapperTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers the per-agency field mapper
  (`col.agency_config`'s `import_mapping`/`activity_type_map`/`date_format`/
  `export_mapping`) added on top of COL-P4's `AgencyDesk` — agencies whose
  file layout doesn't already match this repo's own field names/vocabulary/
  date format. Same fixture pattern as `ColComponentTest`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, BalanceBucket}
  alias VmuCore.COL.{AgencyDesk, CollectionCase}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter,
                        ModuleConfigWriter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp parameter_hierarchy_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, description: "test",
      payment_channels_enabled: "gateway,direct_debit,agency"
    })
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    # ParameterEngine's ETS cache only loads at boot / on explicit refresh —
    # a freshly-inserted BankParameter row (payment_channels_enabled here)
    # isn't visible to PaymentIntake.enabled_channels/1 without this.
    VmuCore.Shared.ParameterEngine.refresh_all()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Mapper", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "MAP-TEST-#{n}"
      })
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "map-test-pan-#{n}", last_four: "7777",
        expiry_date: "1230", credit_limit: D.new("10000.00")
      })
      |> Repo.insert!()

    %BalanceBucket{}
    |> BalanceBucket.changeset(%{account_id: account.account_id, balance_date: Date.utc_today()})
    |> Repo.insert!()

    account
  end

  defp case_fixture(account) do
    %CollectionCase{}
    |> CollectionCase.changeset(%{
      account_id: account.account_id, dpd_bucket: 90,
      outstanding_amount: D.new("500.00"), status: "OPEN"
    })
    |> Repo.insert!()
  end

  defp configure_agency(account, code, cfg) do
    ModuleConfigWriter.put(
      "col", "agency_config", %{code => cfg},
      %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
    )
  end

  describe "import with a mapped file layout" do
    test "remaps headers, translates activity_type values, and parses a custom date format" do
      account = account_fixture()
      case_row = case_fixture(account)

      configure_agency(account, "MAPPED1", %{
        "file_format" => "CSV",
        "commission_type" => "flat_percent", "commission_value" => "5",
        "import_mapping" => %{
          "AcctNo" => "account_id", "Type" => "activity_type",
          "PmtAmt" => "amount", "Date" => "activity_date"
        },
        "activity_type_map" => %{"PYMT" => "PAYMENT"},
        "date_format" => "%m/%d/%Y"
      })

      {:ok, _placement} = AgencyDesk.place(case_row.case_id, "MAPPED1")

      csv = "AcctNo,Type,PmtAmt,Date\n#{account.account_id},PYMT,150.00,07/15/2026\n"

      assert {:ok, %{applied: 1, rejected: 0}} =
               AgencyDesk.import_activity_file("MAPPED1", account.sys_id, account.bank_id, csv)

      activity = Repo.one!(VmuCore.COL.AgencyActivity)
      assert activity.activity_type == "PAYMENT"
      assert D.equal?(activity.amount, D.new("150.00"))
      assert activity.activity_date == ~D[2026-07-15]
      assert activity.status == "APPLIED"
    end

    test "rejects an unmapped row the same way an identity-format bad row would" do
      account = account_fixture()
      case_row = case_fixture(account)

      configure_agency(account, "MAPPED2", %{
        "file_format" => "CSV",
        "import_mapping" => %{"AcctNo" => "account_id", "Type" => "activity_type"}
      })

      {:ok, _placement} = AgencyDesk.place(case_row.case_id, "MAPPED2")

      # "Type" value "BOGUS" doesn't appear in activity_type_map (absent here)
      # and isn't a valid activity_type on its own -> rejected, not crashed.
      csv = "AcctNo,Type\n#{account.account_id},BOGUS\n"

      assert {:ok, %{applied: 0, rejected: 1}} =
               AgencyDesk.import_activity_file("MAPPED2", account.sys_id, account.bank_id, csv)
    end

    test "an agency with no mapping configured still works exactly as before (identity default)" do
      account = account_fixture()
      case_row = case_fixture(account)

      configure_agency(account, "PLAIN1", %{"file_format" => "CSV"})
      {:ok, _placement} = AgencyDesk.place(case_row.case_id, "PLAIN1")

      csv = "account_id,activity_type,amount,activity_date\n#{account.account_id},CONTACT,,2026-07-01\n"

      assert {:ok, %{applied: 1, rejected: 0}} =
               AgencyDesk.import_activity_file("PLAIN1", account.sys_id, account.bank_id, csv)
    end
  end

  describe "export with a mapped file layout" do
    test "renames CSV headers per export_mapping, keeping canonical column order" do
      account = account_fixture()
      case_row = case_fixture(account)

      configure_agency(account, "MAPPED3", %{
        "file_format" => "CSV",
        "export_mapping" => %{"account_id" => "AcctNo", "outstanding" => "Balance"}
      })

      {:ok, _placement} = AgencyDesk.place(case_row.case_id, "MAPPED3")

      {:ok, content, "CSV"} = AgencyDesk.generate_assignment_file("MAPPED3", account.sys_id, account.bank_id)

      [header | _] = String.split(content, "\n")
      assert header == "AcctNo,last_four,Balance,placed_at"
      assert content =~ to_string(account.account_id)
      assert content =~ "500.00"
    end

    test "renames JSON keys per export_mapping" do
      account = account_fixture()
      case_row = case_fixture(account)

      configure_agency(account, "MAPPED4", %{
        "file_format" => "JSON",
        "export_mapping" => %{"account_id" => "AcctNo"}
      })

      {:ok, _placement} = AgencyDesk.place(case_row.case_id, "MAPPED4")

      {:ok, content, "JSON"} = AgencyDesk.generate_assignment_file("MAPPED4", account.sys_id, account.bank_id)

      assert [row] = Jason.decode!(content)
      assert row["AcctNo"] == to_string(account.account_id)
      # last_four wasn't remapped -> passes through under its own name
      assert row["last_four"] == "7777"
    end

    test "an agency with no export_mapping generates the same plain output as before" do
      account = account_fixture()
      case_row = case_fixture(account)

      configure_agency(account, "PLAIN2", %{"file_format" => "CSV"})
      {:ok, _placement} = AgencyDesk.place(case_row.case_id, "PLAIN2")

      {:ok, content, "CSV"} = AgencyDesk.generate_assignment_file("PLAIN2", account.sys_id, account.bank_id)

      assert String.starts_with?(content, "account_id,last_four,outstanding,placed_at")
    end
  end
end
