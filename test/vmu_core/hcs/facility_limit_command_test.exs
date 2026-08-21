defmodule VmuCore.HCS.FacilityLimitCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 2
  (2026-07-25) — the maker-checker facility limit change workflow.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.HCS.{Company, CompanyOnboarding, FacilityLimitCommand}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter, SysParameter}
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
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp company_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Corporate", last_name: "Test#{n}",
        customer_tier: "CORPORATE", company_name: "Facility Test Co #{n}",
        registration_number: "REG-#{n}"
      })
      |> Repo.insert!()

    {:ok, %{company: company}} =
      CompanyOnboarding.onboard_company(%{
        account_attrs: %{
          customer_id: customer.customer_id,
          sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
          pan_token: "hcs-facility-test-#{n}", last_four: "0000", expiry_date: "0000",
          credit_limit: D.new("100000.00")
        },
        company_attrs: %{
          company_code: "FLC#{n}", company_name: "Facility Test Co #{n}",
          registration_no: "REG-#{n}", liability_model: "CENTRAL",
          credit_limit: D.new("100000.00")
        }
      })

    {company, sys_id, bank_id}
  end

  describe "request/3" do
    test "parks a PENDING_APPROVAL change with the real current_limit snapshotted" do
      {company, _sys_id, _bank_id} = company_fixture()

      assert {:ok, change} =
               FacilityLimitCommand.request(company.id, D.new("150000.00"),
                 reason: "growth", requested_by: "maker1")

      assert change.status == "PENDING_APPROVAL"
      assert D.equal?(change.current_limit, D.new("100000.00"))
      assert D.equal?(change.requested_limit, D.new("150000.00"))
    end

    test "an unknown company is a clean error" do
      assert {:error, :not_found} = FacilityLimitCommand.request(999_999_999, D.new("1000"), requested_by: "maker1")
    end
  end

  describe "approve/2" do
    test "applies the new limit and adjusts available_limit by the delta" do
      {company, sys_id, bank_id} = company_fixture()

      ModuleConfigWriter.put("hcs", "facility_limit_approval_matrix", ["SUPERVISOR"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      {:ok, change} = FacilityLimitCommand.request(company.id, D.new("150000.00"), requested_by: "maker1")

      assert {:ok, approved} = FacilityLimitCommand.approve(change.id, %{username: "checker1", role: "SUPERVISOR"})
      assert approved.status == "APPROVED"

      reloaded = Repo.get!(Company, company.id)
      assert D.equal?(reloaded.credit_limit, D.new("150000.00"))
      # available_limit started at 100000 (== credit_limit at onboarding); delta is +50000.
      assert D.equal?(reloaded.available_limit, D.new("150000.00"))
    end

    test "maker cannot approve their own request" do
      {company, sys_id, bank_id} = company_fixture()

      ModuleConfigWriter.put("hcs", "facility_limit_approval_matrix", ["SUPERVISOR"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      {:ok, change} = FacilityLimitCommand.request(company.id, D.new("150000.00"), requested_by: "maker1")

      assert {:error, :maker_cannot_approve} =
               FacilityLimitCommand.approve(change.id, %{username: "maker1", role: "SUPERVISOR"})
    end

    test "a role not in the approval matrix is rejected" do
      {company, sys_id, bank_id} = company_fixture()

      ModuleConfigWriter.put("hcs", "facility_limit_approval_matrix", ["RISK"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      {:ok, change} = FacilityLimitCommand.request(company.id, D.new("150000.00"), requested_by: "maker1")

      assert {:error, {:role_not_authorized, ["RISK"]}} =
               FacilityLimitCommand.approve(change.id, %{username: "checker1", role: "OPS"})
    end

    test "ADMIN always qualifies regardless of the approval matrix" do
      {company, sys_id, bank_id} = company_fixture()

      ModuleConfigWriter.put("hcs", "facility_limit_approval_matrix", ["RISK"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      {:ok, change} = FacilityLimitCommand.request(company.id, D.new("150000.00"), requested_by: "maker1")

      assert {:ok, _} = FacilityLimitCommand.approve(change.id, %{username: "admin1", role: "ADMIN"})
    end

    test "a non-pending change cannot be approved again" do
      {company, sys_id, bank_id} = company_fixture()

      ModuleConfigWriter.put("hcs", "facility_limit_approval_matrix", ["SUPERVISOR"],
        %{scope_type: "bank", sys_id: sys_id, bank_id: bank_id}, nil)

      {:ok, change} = FacilityLimitCommand.request(company.id, D.new("150000.00"), requested_by: "maker1")
      {:ok, _} = FacilityLimitCommand.approve(change.id, %{username: "checker1", role: "SUPERVISOR"})

      assert {:error, {:not_pending, "APPROVED"}} =
               FacilityLimitCommand.approve(change.id, %{username: "checker2", role: "SUPERVISOR"})
    end
  end

  describe "reject/2" do
    test "rejects a pending change without touching the company" do
      {company, _sys_id, _bank_id} = company_fixture()
      {:ok, change} = FacilityLimitCommand.request(company.id, D.new("150000.00"), requested_by: "maker1")

      assert {:ok, rejected} = FacilityLimitCommand.reject(change.id, "checker1")
      assert rejected.status == "REJECTED"

      reloaded = Repo.get!(Company, company.id)
      assert D.equal?(reloaded.credit_limit, D.new("100000.00"))
    end
  end

  describe "pending/1" do
    test "lists only PENDING_APPROVAL changes, oldest first" do
      {company, _sys_id, _bank_id} = company_fixture()
      {:ok, c1} = FacilityLimitCommand.request(company.id, D.new("110000.00"), requested_by: "maker1")
      {:ok, _c2} = FacilityLimitCommand.request(company.id, D.new("120000.00"), requested_by: "maker1")
      {:ok, c3} = FacilityLimitCommand.request(company.id, D.new("130000.00"), requested_by: "maker1")
      {:ok, _} = FacilityLimitCommand.reject(c3.id, "checker1")

      pending = FacilityLimitCommand.pending(100)
      ids = Enum.map(pending, & &1.id)

      assert c1.id in ids
      refute c3.id in ids
    end
  end
end
