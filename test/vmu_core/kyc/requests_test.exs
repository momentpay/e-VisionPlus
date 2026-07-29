defmodule VmuCore.Kyc.RequestsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. KYC-P2 (2026-07-29) — submission
  workflow (submit/approve/reject) + StatusSync, the real integration point
  that keeps the five pre-existing per-product kyc_status flags accurate.
  See docs/kyc/KYC_Implementation_Tracker.md §3.3/§5.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Methods, Requests, Request}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.CMS.{DebitAccount, Arrangement}
  alias VmuCore.HCS.Company

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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp customer_fixture do
    {sys_id, bank_id, _logo_id, _block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    %Customer{}
    |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Kyc", last_name: "Test#{n}"})
    |> Repo.insert!()
  end

  defp debit_account_fixture(customer) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()

    %DebitAccount{}
    |> DebitAccount.changeset(%{
      customer_id: customer.customer_id,
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
      opened_at: Date.utc_today()
    })
    |> Repo.insert!()
  end

  defp company_fixture do
    n = System.unique_integer([:positive])

    %Company{}
    |> Company.changeset(%{
      company_code: "CO#{n}",
      company_name: "Test Company #{n}",
      registration_no: "REG#{n}",
      liability_model: "CENTRAL",
      credit_limit: Decimal.new(100_000),
      available_limit: Decimal.new(100_000)
    })
    |> Repo.insert!()
  end

  defp method_fixture(product_type) do
    n = System.unique_integer([:positive])

    {:ok, method} =
      Methods.create(%{
        "name" => "Method #{n}",
        "title" => "Method Title #{n}",
        "product_type" => product_type,
        "status" => "active",
        "fields" => [
          %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []}
        ]
      })

    method
  end

  describe "submit/2" do
    test "creates a request snapshotting the method's fields and version" do
      customer = customer_fixture()
      method = method_fixture("DEBIT")

      assert {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{"full_name" => "Jane Doe"}})

      assert request.kyc_method_id == method.method_id
      assert request.method_version == method.version
      assert request.fields_snapshot == method.fields
      assert request.product_type == "DEBIT"
      assert request.status == "submitted"
      assert request.application_number != nil
      assert request.submitted_at != nil
    end

    test "a later edit to the method does not change an already-submitted snapshot" do
      customer = customer_fixture()
      method = method_fixture("DEBIT")

      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

      new_fields = method.fields ++ [%{"key" => "extra", "label" => "Extra", "type" => "text", "required" => false, "options" => []}]
      {:ok, _updated_method} = Methods.update(method, %{"fields" => new_fields})

      reloaded = Requests.get!(request.request_id)
      assert reloaded.fields_snapshot == method.fields
      assert length(reloaded.fields_snapshot) == 1
    end
  end

  describe "approve/3 + StatusSync" do
    test "approving a DEBIT request syncs the customer's latest DebitAccount" do
      customer = customer_fixture()
      account = debit_account_fixture(customer)
      assert account.kyc_status == "PENDING"

      method = method_fixture("DEBIT")
      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{"full_name" => "Jane Doe"}})

      operator_id = "00000000-0000-0000-0000-000000000001"
      assert {:ok, approved} = Requests.approve(request, operator_id, "looks good")

      assert approved.status == "approved"
      assert approved.reviewer_id == operator_id
      assert approved.decision_reason == "looks good"
      assert approved.reviewed_at != nil

      reloaded_account = Repo.get!(DebitAccount, account.debit_account_id)
      assert reloaded_account.kyc_status == "VERIFIED"
      assert reloaded_account.kyc_verified_at != nil
    end

    test "rejecting a DEBIT request syncs REJECTED with no verified_at" do
      customer = customer_fixture()
      account = debit_account_fixture(customer)

      method = method_fixture("DEBIT")
      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

      operator_id = "00000000-0000-0000-0000-000000000001"
      assert {:ok, rejected} = Requests.reject(request, operator_id, "missing document")
      assert rejected.status == "rejected"

      reloaded_account = Repo.get!(DebitAccount, account.debit_account_id)
      assert reloaded_account.kyc_status == "REJECTED"
      assert reloaded_account.kyc_verified_at == nil
    end

    test "approving a CREDIT/CORPORATE_EMPLOYEE request syncs the Customer row directly" do
      customer = customer_fixture()
      assert customer.kyc_status == "PENDING"

      method = method_fixture("CORPORATE_EMPLOYEE")
      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

      {:ok, _approved} = Requests.approve(request, "00000000-0000-0000-0000-000000000001", nil)

      reloaded_customer = Repo.get!(Customer, customer.customer_id)
      assert reloaded_customer.kyc_status == "VERIFIED"
      assert reloaded_customer.kyc_verified_at != nil
      assert %NaiveDateTime{} = reloaded_customer.kyc_verified_at
    end

    test "approving a CORPORATE_FACILITY request syncs HCS.Company via the arrangement's account_ref (utc_datetime field)" do
      customer = customer_fixture()
      company = company_fixture()
      assert company.kyc_status == "PENDING"

      {:ok, arrangement} =
        %Arrangement{}
        |> Arrangement.changeset(%{
          customer_id: customer.customer_id,
          product_type: "CORPORATE_FACILITY",
          account_ref: to_string(company.id),
          opened_at: Date.utc_today()
        })
        |> Repo.insert()

      method = method_fixture("CORPORATE_FACILITY")

      {:ok, request} =
        Requests.submit(method, %{
          "customer_id" => customer.customer_id,
          "arrangement_id" => arrangement.id,
          "data" => %{}
        })

      {:ok, _approved} = Requests.approve(request, "00000000-0000-0000-0000-000000000001", nil)

      reloaded_company = Repo.get!(Company, company.id)
      assert reloaded_company.kyc_status == "VERIFIED"
      assert %DateTime{} = reloaded_company.kyc_verified_at
    end

    test "approving is skipped gracefully (not an error) when no account exists yet for the product" do
      customer = customer_fixture()
      method = method_fixture("WALLET")
      {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

      # No WalletAccount exists for this customer -- StatusSync.sync/1 should
      # skip quietly; the request itself still transitions to approved.
      assert {:ok, approved} = Requests.approve(request, "00000000-0000-0000-0000-000000000001", nil)
      assert approved.status == "approved"
    end
  end

  describe "list/1" do
    test "filters by product_type and status" do
      customer = customer_fixture()
      method = method_fixture("DEBIT")
      {:ok, _r1} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

      results = Requests.list(%{"product_type" => "DEBIT", "status" => "submitted"})
      assert Enum.all?(results, &(&1.product_type == "DEBIT" and &1.status == "submitted"))
      assert length(results) >= 1
    end
  end

  describe "Request.changeset/2" do
    test "rejects a product_type outside CMS.Arrangement.product_types/0" do
      customer = customer_fixture()
      method = method_fixture("DEBIT")

      changeset =
        Request.changeset(%Request{}, %{
          "kyc_method_id" => method.method_id,
          "method_version" => 1,
          "fields_snapshot" => [],
          "customer_id" => customer.customer_id,
          "product_type" => "NOT_A_REAL_PRODUCT"
        })

      refute changeset.valid?
    end
  end
end
