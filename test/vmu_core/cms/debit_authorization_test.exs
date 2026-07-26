defmodule VmuCore.CMS.DebitAuthorizationTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 4
  (Debit, D3) — real-time balance authorization: an atomic decrement, no
  Horde GenServer needed (no OTB cascade to protect, unlike credit).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{DebitAccount, DebitAccountOpening, DebitAuthorization, DebitFundingCommand}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp funded_debit_account_fixture(initial_balance \\ D.new("500.00")) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "555555", description: "test", product_type: "DEBIT"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Debit", last_name: "AuthTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    {:ok, _} =
      DebitFundingCommand.fund(%{
        debit_account_id: account.debit_account_id, amount: initial_balance,
        channel: "ADMIN_MANUAL", posted_by: "operator1"
      })

    account
  end

  test "authorize/2 decrements available_balance when funds are sufficient" do
    account = funded_debit_account_fixture(D.new("500.00"))

    assert {:ok, new_balance} = DebitAuthorization.authorize(account.debit_account_id, D.new("120.00"))
    assert D.equal?(new_balance, D.new("380.00"))

    reloaded = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded.available_balance, D.new("380.00"))
  end

  test "authorize/2 declines when funds are insufficient, leaving balance untouched" do
    account = funded_debit_account_fixture(D.new("50.00"))

    assert {:error, :insufficient_funds} = DebitAuthorization.authorize(account.debit_account_id, D.new("100.00"))

    reloaded = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded.available_balance, D.new("50.00"))
  end

  test "authorize/2 allows spending exactly the full available balance" do
    account = funded_debit_account_fixture(D.new("75.00"))

    assert {:ok, new_balance} = DebitAuthorization.authorize(account.debit_account_id, D.new("75.00"))
    assert D.equal?(new_balance, D.new(0))
  end

  test "authorize/2 rejects a suspended account" do
    account = funded_debit_account_fixture()

    account |> DebitAccount.changeset(%{status: "SUSPENDED"}) |> Repo.update!()

    assert {:error, :not_active} = DebitAuthorization.authorize(account.debit_account_id, D.new("10.00"))
  end

  test "authorize/2 returns :not_found for an unknown account" do
    assert {:error, :not_found} = DebitAuthorization.authorize(Ecto.UUID.generate(), D.new("10.00"))
  end

  test "credit/2 restores available_balance" do
    account = funded_debit_account_fixture(D.new("200.00"))
    {:ok, _} = DebitAuthorization.authorize(account.debit_account_id, D.new("60.00"))

    :ok = DebitAuthorization.credit(account.debit_account_id, D.new("60.00"))

    reloaded = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded.available_balance, D.new("200.00"))
  end

  test "concurrent authorizations against the same balance never oversell it" do
    account = funded_debit_account_fixture(D.new("100.00"))
    test_pid = self()

    results =
      1..5
      |> Task.async_stream(fn _ ->
        Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
        DebitAuthorization.authorize(account.debit_account_id, D.new("30.00"))
      end, max_concurrency: 5)
      |> Enum.map(fn {:ok, result} -> result end)

    approved = Enum.count(results, &match?({:ok, _}, &1))
    declined = Enum.count(results, &match?({:error, :insufficient_funds}, &1))

    # 100.00 balance / 30.00 each = at most 3 can succeed.
    assert approved == 3
    assert declined == 2

    reloaded = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded.available_balance, D.new("10.00"))
  end

  test "debit_account?/1 distinguishes debit accounts from anything else" do
    account = funded_debit_account_fixture()

    assert DebitAuthorization.debit_account?(account.debit_account_id)
    refute DebitAuthorization.debit_account?(Ecto.UUID.generate())
  end
end
