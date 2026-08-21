defmodule VmuCore.Kyc.JourneyTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. KYC-P3.5 (2026-07-29) — sequential
  step gating, confirmed with the user as the "sequential gate" option
  (not just informational ordering). See docs/kyc/KYC_Implementation_Tracker.md.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Methods, Requests, Journey}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

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

    {sys_id, bank_id}
  end

  defp customer_fixture do
    {sys_id, bank_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    %Customer{}
    |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Journey", last_name: "Test#{n}"})
    |> Repo.insert!()
  end

  defp method_fixture(step, required \\ true) do
    n = System.unique_integer([:positive])

    {:ok, method} =
      Methods.create(%{
        "name" => "Step #{step} Method #{n}",
        "title" => "Step #{step}",
        "product_type" => "PREPAID",
        "status" => "active",
        "step" => step,
        "required" => required,
        "fields" => [%{"key" => "note", "label" => "Note", "type" => "text", "required" => false, "options" => []}]
      })

    method
  end

  describe "progress/2" do
    test "step 1 is :current when nothing submitted yet, later steps are :locked" do
      customer = customer_fixture()
      _step1 = method_fixture(1)
      _step2 = method_fixture(2)

      progress = Journey.progress(customer.customer_id, "PREPAID")
      statuses = Enum.map(progress, & &1.status)

      assert statuses == [:current, :locked]
    end

    test "approving step 1 unlocks step 2" do
      customer = customer_fixture()
      step1 = method_fixture(1)
      _step2 = method_fixture(2)

      {:ok, request} = Requests.submit(step1, %{"customer_id" => customer.customer_id, "data" => %{}})
      {:ok, _} = Requests.approve(request, "00000000-0000-0000-0000-000000000001")

      progress = Journey.progress(customer.customer_id, "PREPAID")
      statuses = Enum.map(progress, & &1.status)

      assert statuses == [:done, :current]
    end

    test "a non-required step doesn't block a later step" do
      customer = customer_fixture()
      _step1 = method_fixture(1, false)
      step2 = method_fixture(2)

      assert Journey.submittable?(customer.customer_id, step2)
    end

    test "a rejected step 1 leaves step 2 locked" do
      customer = customer_fixture()
      step1 = method_fixture(1)
      step2 = method_fixture(2)

      {:ok, request} = Requests.submit(step1, %{"customer_id" => customer.customer_id, "data" => %{}})
      {:ok, _} = Requests.reject(request, "00000000-0000-0000-0000-000000000001", "missing info")

      refute Journey.submittable?(customer.customer_id, step2)
    end
  end

  describe "Requests.submit/2 gating" do
    test "rejects submission for a locked step" do
      customer = customer_fixture()
      _step1 = method_fixture(1)
      step2 = method_fixture(2)

      assert {:error, :step_locked} = Requests.submit(step2, %{"customer_id" => customer.customer_id, "data" => %{}})
    end

    test "allows submission once the prior required step is approved" do
      customer = customer_fixture()
      step1 = method_fixture(1)
      step2 = method_fixture(2)

      {:ok, request1} = Requests.submit(step1, %{"customer_id" => customer.customer_id, "data" => %{}})
      {:ok, _} = Requests.approve(request1, "00000000-0000-0000-0000-000000000001")

      assert {:ok, request2} = Requests.submit(step2, %{"customer_id" => customer.customer_id, "data" => %{}})
      assert request2.step == 2
    end
  end
end
