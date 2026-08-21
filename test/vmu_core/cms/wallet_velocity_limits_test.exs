defmodule VmuCore.CMS.WalletVelocityLimitsTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Digital Wallet Phase W5 follow-up
  (2026-07-29) — pure check-module unit tests for the `velocity_limits`
  read side. See docs/wallet/DIGITAL_WALLET_Module_Requirements.md W009.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{WalletAccount, WalletFunding, WalletProductOpening, WalletVelocityLimits}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp wallet_fixture(limits \\ %{}) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Velocity", last_name: "Test#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "Velocity Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    account
    |> WalletAccount.changeset(%{velocity_limits: limits})
    |> Repo.update!()
  end

  defp record_funding(account, amount) do
    %WalletFunding{}
    |> WalletFunding.changeset(%{
      wallet_account_id: account.wallet_account_id, amount: amount,
      channel: "ADMIN_MANUAL", posted_by: "test"
    })
    |> Repo.insert!()
  end

  test "an account with no configured limits is unlimited" do
    account = wallet_fixture()
    assert WalletVelocityLimits.check(account, D.new("1000000")) == :ok
  end

  test "a daily count cap declines once today's count would exceed it" do
    account = wallet_fixture(%{"DAILY" => %{"count" => 2}})

    record_funding(account, D.new("10"))
    assert WalletVelocityLimits.check(account, D.new("10")) == :ok

    record_funding(account, D.new("10"))
    assert {:error, %{type: "DAILY_COUNT", limit: 2}} = WalletVelocityLimits.check(account, D.new("10"))
  end

  test "a daily amount cap declines once today's total plus the new amount would exceed it" do
    account = wallet_fixture(%{"DAILY" => %{"amount" => 1000}})

    record_funding(account, D.new("600"))
    assert WalletVelocityLimits.check(account, D.new("400")) == :ok

    assert {:error, %{type: "DAILY_AMOUNT", limit: 1000}} =
             WalletVelocityLimits.check(account, D.new("400.01"))
  end

  test "a monthly amount cap declines once this month's total plus the new amount would exceed it" do
    account = wallet_fixture(%{"MONTHLY" => %{"amount" => 5000}})

    record_funding(account, D.new("4900"))

    assert {:error, %{type: "MONTHLY_AMOUNT", limit: 5000}} =
             WalletVelocityLimits.check(account, D.new("200"))
  end

  test "a funding on a different account never counts toward this account's limit" do
    account = wallet_fixture(%{"DAILY" => %{"count" => 1}})
    other = wallet_fixture(%{})

    record_funding(other, D.new("10"))
    assert WalletVelocityLimits.check(account, D.new("10")) == :ok
  end
end
