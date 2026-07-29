defmodule VmuCore.Kyc.RiskScreeningTest do
  @moduledoc """
  Real Postgres via Sandbox + a real (non-HTTP) call into `mw_risk`, no
  mocking. KYC-P4 (2026-07-29) — sanctions screening gate on approval.
  See docs/kyc/KYC_Implementation_Tracker.md §7.

  Only the `:clear` path is exercised here with real data — confirmed live
  before wiring this in that `CDM.SanctionsScreening.screen/1` responds
  correctly and quickly (~50ms) against the test environment's `mw_risk`
  sanctions list. The `{:hit, _}`/`:error` branches in `Kyc.Requests.
  approve/3` are real code, not stubs, but this repo has no way to seed a
  known sanctions match into `mw_risk`'s own database (a separate app/DB
  this build doesn't own) — an honest gap, not a skipped assertion pretending
  to be covered.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.Kyc.{Methods, Requests, RiskScreening}
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

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    {sys_id, bank_id}
  end

  defp customer_fixture do
    {sys_id, bank_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    %Customer{}
    |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Risk", last_name: "ScreenTest#{n}"})
    |> Repo.insert!()
  end

  test "screen_request/1 returns :clear for an ordinary customer" do
    customer = customer_fixture()

    {:ok, method} =
      Methods.create(%{
        "name" => "Risk Screen Method #{System.unique_integer([:positive])}",
        "title" => "Risk Screen Method",
        "product_type" => "DEBIT",
        "status" => "active",
        "fields" => []
      })

    {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})

    assert RiskScreening.screen_request(request) == :clear
  end

  test "screen_request/1 returns :error when the customer no longer exists" do
    fake_request = %VmuCore.Kyc.Request{customer_id: Ecto.UUID.generate()}
    assert RiskScreening.screen_request(fake_request) == :error
  end

  test "Requests.approve/3 proceeds to StatusSync on a clear screen" do
    customer = customer_fixture()

    {:ok, method} =
      Methods.create(%{
        "name" => "Approve Screen Method #{System.unique_integer([:positive])}",
        "title" => "Approve Screen Method",
        "product_type" => "CREDIT",
        "status" => "active",
        "fields" => []
      })

    {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => %{}})
    assert {:ok, approved} = Requests.approve(request, "00000000-0000-0000-0000-000000000001")
    assert approved.status == "approved"

    reloaded_customer = Repo.get!(Customer, customer.customer_id)
    assert reloaded_customer.kyc_status == "VERIFIED"
  end
end
