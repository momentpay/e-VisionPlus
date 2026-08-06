defmodule VmuCore.CMS.WalletW1Test do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Digital Wallet Phase W1
  (2026-07-28) — account/ledger foundation: WalletProduct grouping,
  WalletAccount open/load/withdraw/close, block/unblock, non-monetary
  events. See docs/wallet/DIGITAL_WALLET_Module_Requirements.md.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{
    WalletAccount, WalletProductOpening, WalletFundingCommand,
    WalletWithdrawalCommand, WalletAccountClosure, WalletBlockHistory,
    WalletNonMonetaryEvent, Arrangement
  }
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  import Ecto.Query

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

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. Production gets
    # all three from `seed_gl.exs`; a test that mints an institution inline has
    # to supply them. See `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(sys_id, bank_id)
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp wallet_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Wal", last_name: "LetTest#{n}"})
      |> Repo.insert!()

    {:ok, %{product: product, account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "Main Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    {product, account, customer}
  end

  test "opening a wallet product creates its first account and records an Arrangement" do
    {product, account, customer} = wallet_fixture()

    assert account.wallet_product_id == product.wallet_product_id
    assert account.customer_id == customer.customer_id
    assert account.status == "ACTIVE"
    assert D.equal?(account.available_balance, D.new(0))

    arrangement = Repo.get_by!(Arrangement, product_type: "WALLET", account_ref: product.wallet_product_id)
    assert arrangement.customer_id == customer.customer_id
  end

  test "funding a wallet account posts a real GL entry and increments the balance" do
    {_product, account, _customer} = wallet_fixture()

    assert {:ok, %{funding: funding, ledger_entry: entry}} =
             WalletFundingCommand.fund(%{
               wallet_account_id: account.wallet_account_id, amount: D.new("250.00"),
               channel: "ADMIN_MANUAL", posted_by: "test_operator"
             })

    assert D.equal?(funding.amount, D.new("250.00"))
  # Account codes remapped by GL Phase 4A (VMU-ADR-005): stored value moved
  # out of the 5xxx expense range into 2xxx liabilities, and cash clearing
  # from 1006 (an HCS receivable) to 3005.
    assert entry.dr_gl_account == "3005"
    assert entry.cr_gl_account == "2006"

    updated = Repo.get!(WalletAccount, account.wallet_account_id)
    assert D.equal?(updated.available_balance, D.new("250.00"))

    assert {:ok, balance} = WalletFundingCommand.balance(account.wallet_account_id)
    assert D.equal?(balance, D.new("250.00"))
  end

  test "external funding channel requires a reference" do
    {_product, account, _customer} = wallet_fixture()

    assert {:error, changeset} =
             WalletFundingCommand.fund(%{
               wallet_account_id: account.wallet_account_id, amount: D.new("100.00"),
               channel: "EXTERNAL_BANK_TRANSFER", posted_by: "test_operator"
             })

    refute changeset.valid?
    assert %{external_reference: ["can't be blank"]} = errors_on(changeset)

    unchanged = Repo.get!(WalletAccount, account.wallet_account_id)
    assert D.equal?(unchanged.available_balance, D.new(0))
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  test "withdrawal atomically decrements balance and rejects when insufficient" do
    {_product, account, _customer} = wallet_fixture()

    {:ok, _} =
      WalletFundingCommand.fund(%{
        wallet_account_id: account.wallet_account_id, amount: D.new("100.00"),
        channel: "ADMIN_MANUAL", posted_by: "test_operator"
      })

    assert {:ok, %{new_balance: new_balance}} =
             WalletWithdrawalCommand.withdraw(
               account.wallet_account_id, D.new("40.00"), "test withdrawal",
               "wallet_wd_test_#{System.unique_integer([:positive])}"
             )

    assert D.equal?(new_balance, D.new("60.00"))

    assert {:error, :insufficient_funds} =
             WalletWithdrawalCommand.withdraw(
               account.wallet_account_id, D.new("999.00"), "over-withdraw",
               "wallet_wd_test_#{System.unique_integer([:positive])}"
             )

    unchanged = Repo.get!(WalletAccount, account.wallet_account_id)
    assert D.equal?(unchanged.available_balance, D.new("60.00"))
  end

  test "closing a wallet account requires a zero balance" do
    {_product, account, _customer} = wallet_fixture()

    {:ok, _} =
      WalletFundingCommand.fund(%{
        wallet_account_id: account.wallet_account_id, amount: D.new("10.00"),
        channel: "ADMIN_MANUAL", posted_by: "test_operator"
      })

    assert {:error, :balance_not_zero} = WalletAccountClosure.close(account.wallet_account_id)

    {:ok, _} =
      WalletWithdrawalCommand.withdraw(
        account.wallet_account_id, D.new("10.00"), "drain for closure",
        "wallet_close_test_#{System.unique_integer([:positive])}"
      )

    assert {:ok, closed} = WalletAccountClosure.close(account.wallet_account_id)
    assert closed.status == "CLOSED"
    assert closed.closed_at == Date.utc_today()
  end

  test "account-level block and unblock, history recorded" do
    {_product, account, _customer} = wallet_fixture()
    operator_id = Ecto.UUID.generate()

    assert {:ok, entry} =
             WalletBlockHistory.record_block(
               account.wallet_account_id, "F", "FRAUD_ALERT", "Suspicious activity", operator_id, "SUPERVISOR"
             )

    assert entry.action == "BLOCKED"
    updated = Repo.get!(WalletAccount, account.wallet_account_id)
    assert updated.block_code == "F"

    assert {:ok, unblock_entry} =
             WalletBlockHistory.record_unblock(
               account.wallet_account_id, "F", "INVESTIGATION_CLOSED", "Confirmed genuine", operator_id, "SUPERVISOR"
             )

    assert unblock_entry.action == "UNBLOCKED"
    cleared = Repo.get!(WalletAccount, account.wallet_account_id)
    assert is_nil(cleared.block_code)

    history = WalletBlockHistory.history_for(account.wallet_account_id)
    assert length(history) == 2
  end

  test "non-monetary event recorded and queryable" do
    {_product, account, _customer} = wallet_fixture()

    assert {:ok, event} =
             WalletNonMonetaryEvent.record(
               wallet_account_id: account.wallet_account_id,
               event_type: "email_change",
               old_value: %{"email" => "old@example.com"},
               new_value: %{"email" => "new@example.com"},
               reason: "Customer request",
               operator_id: Ecto.UUID.generate()
             )

    assert event.event_type == "email_change"
    [listed] = WalletNonMonetaryEvent.history_for(account.wallet_account_id)
    assert listed.id == event.id
  end

  test "a wallet product can hold a second single-currency account" do
    {product, _account, _customer} = wallet_fixture()
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()

    assert {:ok, usd_account} =
             VmuCore.CMS.WalletProductOpening.add_currency_account(%{
               wallet_product_id: product.wallet_product_id,
               sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id,
               currency: "USD"
             })

    assert usd_account.wallet_product_id == product.wallet_product_id
    assert usd_account.currency == "USD"

    accounts = Repo.all(from a in WalletAccount, where: a.wallet_product_id == ^product.wallet_product_id)
    assert length(accounts) == 2
  end
end
