defmodule VmuCore.CMS.WalletTransferCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Digital Wallet Phase W2
  (2026-07-28) — wallet-to-wallet transfer. See
  docs/wallet/DIGITAL_WALLET_Module_Requirements.md.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{WalletAccount, WalletProductOpening, WalletFundingCommand, WalletTransferCommand}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp wallet_fixture(name, opts \\ []) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: name, last_name: "XferTest#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "#{name} Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
        currency: Keyword.get(opts, :currency, "AED")
      })

    if load = opts[:load] do
      {:ok, _} =
        WalletFundingCommand.fund(%{
          wallet_account_id: account.wallet_account_id, amount: load,
          channel: "ADMIN_MANUAL", posted_by: "seed"
        })
    end

    Repo.get!(WalletAccount, account.wallet_account_id)
  end

  test "a successful transfer moves the exact amount and conserves total money" do
    sender = wallet_fixture("Sender", load: D.new("500.00"))
    receiver = wallet_fixture("Receiver")
    total_before = D.add(sender.available_balance, receiver.available_balance)

    assert {:ok, transfer} =
             WalletTransferCommand.transfer(%{
               from_wallet_account_id: sender.wallet_account_id,
               to_wallet_account_id: receiver.wallet_account_id,
               amount: D.new("150.00"), initiated_by: "test_operator", reason: "rent"
             })

    assert transfer.status == "COMPLETED"
    assert D.equal?(transfer.amount, D.new("150.00"))

    updated_sender = Repo.get!(WalletAccount, sender.wallet_account_id)
    updated_receiver = Repo.get!(WalletAccount, receiver.wallet_account_id)

    assert D.equal?(updated_sender.available_balance, D.new("350.00"))
    assert D.equal?(updated_receiver.available_balance, D.new("150.00"))

    total_after = D.add(updated_sender.available_balance, updated_receiver.available_balance)
    assert D.equal?(total_before, total_after)

    funding = Repo.get_by!(VmuCore.CMS.WalletFunding, wallet_account_id: receiver.wallet_account_id)
    assert funding.channel == "INTERNAL_TRANSFER"
    assert funding.external_reference == to_string(transfer.id)
  end

  test "insufficient funds rolls back atomically — neither balance changes, no transfer/funding row persists" do
    sender = wallet_fixture("PoorSender", load: D.new("50.00"))
    receiver = wallet_fixture("Receiver2")

    assert {:error, :insufficient_funds} =
             WalletTransferCommand.transfer(%{
               from_wallet_account_id: sender.wallet_account_id,
               to_wallet_account_id: receiver.wallet_account_id,
               amount: D.new("999.00"), initiated_by: "test_operator"
             })

    unchanged_sender = Repo.get!(WalletAccount, sender.wallet_account_id)
    unchanged_receiver = Repo.get!(WalletAccount, receiver.wallet_account_id)

    assert D.equal?(unchanged_sender.available_balance, D.new("50.00"))
    assert D.equal?(unchanged_receiver.available_balance, D.new(0))

    refute Repo.get_by(VmuCore.CMS.WalletTransfer, from_wallet_account_id: sender.wallet_account_id)
    refute Repo.get_by(VmuCore.CMS.WalletFunding, wallet_account_id: receiver.wallet_account_id)
  end

  test "cross-currency transfer is rejected" do
    sender = wallet_fixture("AedSender", load: D.new("100.00"))
    receiver = wallet_fixture("UsdReceiver", currency: "USD")

    assert {:error, :currency_mismatch} =
             WalletTransferCommand.transfer(%{
               from_wallet_account_id: sender.wallet_account_id,
               to_wallet_account_id: receiver.wallet_account_id,
               amount: D.new("10.00"), initiated_by: "test_operator"
             })
  end

  test "transfer to the same account is rejected" do
    account = wallet_fixture("SelfXfer", load: D.new("100.00"))

    assert {:error, :cannot_transfer_to_self} =
             WalletTransferCommand.transfer(%{
               from_wallet_account_id: account.wallet_account_id,
               to_wallet_account_id: account.wallet_account_id,
               amount: D.new("10.00"), initiated_by: "test_operator"
             })
  end

  test "transfer from a blocked (SUSPENDED) sender is rejected" do
    sender = wallet_fixture("BlockedSender", load: D.new("100.00"))
    receiver = wallet_fixture("Receiver3")

    sender
    |> VmuCore.CMS.WalletAccount.changeset(%{status: "SUSPENDED"})
    |> Repo.update!()

    assert {:error, :sender_not_active} =
             WalletTransferCommand.transfer(%{
               from_wallet_account_id: sender.wallet_account_id,
               to_wallet_account_id: receiver.wallet_account_id,
               amount: D.new("10.00"), initiated_by: "test_operator"
             })
  end
end
