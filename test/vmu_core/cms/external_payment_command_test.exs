defmodule VmuCore.CMS.ExternalPaymentCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, real `mw_risk` fraud-scoring pipeline (no
  mocking of the risk gate — proven fast/safe against the real pipeline,
  same posture as `Kyc.RiskScreening`'s probe before wiring it in). Only
  the rail adapter boundary is swapped per-test (`CMS.RailProvider`
  config), same pattern as `Kyc.Adapters.OcrHttpAdapter`'s `Req.Test`
  stub. Digital Wallet Phase W6 (2026-07-29) — A2A (W011) / Instant
  Payments (W012). See docs/wallet/DIGITAL_WALLET_Module_Requirements.md.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{WalletAccount, WalletProductOpening, WalletFundingCommand, ExternalPaymentCommand}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    on_exit(fn -> Application.delete_env(:vmu_core, :rail_provider) end)
    :ok
  end

  defmodule AcceptingRail do
    @behaviour VmuCore.CMS.RailProvider
    @impl true
    def initiate(_payment), do: {:ok, %{external_reference: "RAIL-REF-1", status: "completed"}}
    @impl true
    def check_status(_payment), do: {:ok, %{status: "completed"}}
  end

  defmodule DecliningRail do
    @behaviour VmuCore.CMS.RailProvider
    @impl true
    def initiate(_payment), do: {:error, :bank_timeout}
    @impl true
    def check_status(_payment), do: {:error, :bank_timeout}
  end

  defp wallet_fixture(load \\ D.new("1000")) do
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
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "A2A", last_name: "Test#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "A2A Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    {:ok, _} =
      WalletFundingCommand.fund(%{
        wallet_account_id: account.wallet_account_id, amount: load,
        channel: "ADMIN_MANUAL", posted_by: "test"
      })

    Repo.get!(WalletAccount, account.wallet_account_id)
  end

  defp payment_attrs(account, overrides \\ %{}) do
    Map.merge(
      %{
        wallet_account_id: account.wallet_account_id, rail_type: "A2A",
        amount: D.new("100"), currency: "AED",
        destination: %{"account_number" => "AE070331234567890123456", "bank_name" => "Test Bank"},
        initiated_by: "test_operator"
      },
      overrides
    )
  end

  test "with no rail configured (the real default), the debit is reversed and the payment ends failed" do
    account = wallet_fixture()

    assert {:error, {{:rail_error, :rail_not_configured}, payment}} =
             ExternalPaymentCommand.initiate(payment_attrs(account))

    assert payment.status == "failed"
    assert payment.failure_reason =~ "rail_not_configured"
    assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new("1000"))
  end

  test "an accepting rail completes the payment and permanently debits the wallet" do
    Application.put_env(:vmu_core, :rail_provider, AcceptingRail)
    account = wallet_fixture()

    assert {:ok, payment} = ExternalPaymentCommand.initiate(payment_attrs(account))

    assert payment.status == "completed"
    assert payment.external_reference == "RAIL-REF-1"
    assert payment.risk_decision["decision"] == "approve"
    assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new("900"))
  end

  test "a rail-level decline reverses the debit, leaving the balance unchanged" do
    Application.put_env(:vmu_core, :rail_provider, DecliningRail)
    account = wallet_fixture()

    assert {:error, {{:rail_error, :bank_timeout}, payment}} =
             ExternalPaymentCommand.initiate(payment_attrs(account))

    assert payment.status == "failed"
    assert payment.failure_reason =~ "bank_timeout"
    assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new("1000"))
  end

  test "insufficient funds is recorded on the payment without ever reaching the rail" do
    Application.put_env(:vmu_core, :rail_provider, AcceptingRail)
    account = wallet_fixture(D.new("10"))

    assert {:error, {:insufficient_funds, payment}} =
             ExternalPaymentCommand.initiate(payment_attrs(account, %{amount: D.new("500")}))

    assert payment.status == "failed"
    assert payment.failure_reason =~ "insufficient_funds"
  end

  test "instant payments use the same pipeline, distinguished only by rail_type" do
    Application.put_env(:vmu_core, :rail_provider, AcceptingRail)
    account = wallet_fixture()

    assert {:ok, payment} = ExternalPaymentCommand.initiate(payment_attrs(account, %{rail_type: "INSTANT"}))
    assert payment.rail_type == "INSTANT"
    assert payment.status == "completed"
  end
end
