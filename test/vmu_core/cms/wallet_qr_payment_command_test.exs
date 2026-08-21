defmodule VmuCore.CMS.WalletQrPaymentCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Digital Wallet Phase W3
  (2026-07-28) — scan-to-pay: a QR resolves into a real transfer.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{
    WalletAccount, WalletProductOpening, WalletFundingCommand,
    WalletQrIdentity, WalletQrPaymentCommand
  }
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

  defp wallet_fixture(name, opts \\ []) do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: name, last_name: "QrTest#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "#{name} Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
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

  test "paying a fixed-amount QR moves the exact encoded amount" do
    payer = wallet_fixture("Payer", load: D.new("100.00"))
    payee = wallet_fixture("Payee")

    qr = WalletQrIdentity.generate(payee.wallet_account_id, payee.currency, D.new("30.00"), "Lunch")

    assert {:ok, transfer} =
             WalletQrPaymentCommand.pay(%{
               qr_string: qr, from_wallet_account_id: payer.wallet_account_id,
               initiated_by: "payer_op"
             })

    assert D.equal?(transfer.amount, D.new("30.00"))
    assert transfer.reason == "Lunch"

    assert D.equal?(Repo.get!(WalletAccount, payer.wallet_account_id).available_balance, D.new("70.00"))
    assert D.equal?(Repo.get!(WalletAccount, payee.wallet_account_id).available_balance, D.new("30.00"))
  end

  test "paying an open-amount QR uses the payer-entered amount" do
    payer = wallet_fixture("Payer2", load: D.new("100.00"))
    payee = wallet_fixture("Payee2")

    qr = WalletQrIdentity.generate(payee.wallet_account_id, payee.currency)

    assert {:ok, transfer} =
             WalletQrPaymentCommand.pay(%{
               qr_string: qr, from_wallet_account_id: payer.wallet_account_id,
               initiated_by: "payer_op", amount: D.new("42.00")
             })

    assert D.equal?(transfer.amount, D.new("42.00"))
  end

  test "an open-amount QR paid with no amount is rejected" do
    payer = wallet_fixture("Payer3", load: D.new("100.00"))
    payee = wallet_fixture("Payee3")

    qr = WalletQrIdentity.generate(payee.wallet_account_id, payee.currency)

    assert {:error, :amount_required} =
             WalletQrPaymentCommand.pay(%{
               qr_string: qr, from_wallet_account_id: payer.wallet_account_id,
               initiated_by: "payer_op"
             })
  end

  test "a fixed-amount QR paid with a mismatched payer amount is rejected" do
    payer = wallet_fixture("Payer4", load: D.new("100.00"))
    payee = wallet_fixture("Payee4")

    qr = WalletQrIdentity.generate(payee.wallet_account_id, payee.currency, D.new("30.00"))

    assert {:error, :amount_mismatch} =
             WalletQrPaymentCommand.pay(%{
               qr_string: qr, from_wallet_account_id: payer.wallet_account_id,
               initiated_by: "payer_op", amount: D.new("50.00")
             })
  end

  test "a tampered QR is rejected before touching any balance" do
    payer = wallet_fixture("Payer5", load: D.new("100.00"))
    payee = wallet_fixture("Payee5")

    qr = WalletQrIdentity.generate(payee.wallet_account_id, payee.currency, D.new("30.00"))
    tampered = String.replace(qr, "30.00", "300.00")

    assert {:error, :checksum_mismatch} =
             WalletQrPaymentCommand.pay(%{
               qr_string: tampered, from_wallet_account_id: payer.wallet_account_id,
               initiated_by: "payer_op"
             })

    assert D.equal?(Repo.get!(WalletAccount, payer.wallet_account_id).available_balance, D.new("100.00"))
  end

  test "a well-formed QR encoding a nonexistent account fails gracefully, not a crash" do
    payer = wallet_fixture("Payer6", load: D.new("100.00"))
    ghost_qr = WalletQrIdentity.generate(Ecto.UUID.generate(), "AED", D.new("10.00"))

    assert {:error, :receiver_not_found} =
             WalletQrPaymentCommand.pay(%{
               qr_string: ghost_qr, from_wallet_account_id: payer.wallet_account_id,
               initiated_by: "payer_op"
             })

    assert D.equal?(Repo.get!(WalletAccount, payer.wallet_account_id).available_balance, D.new("100.00"))
  end
end
