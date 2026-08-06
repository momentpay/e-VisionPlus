defmodule VmuCore.CMS.WalletFundingCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Digital Wallet Phase W1 (funding)
  and Phase W5 follow-up (2026-07-29, velocity-limit enforcement + auto
  step-up KYC). See docs/wallet/DIGITAL_WALLET_Module_Requirements.md.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{WalletAccount, WalletFunding, WalletFundingCommand, WalletNonMonetaryEvent, WalletProductOpening}
  alias VmuCore.Kyc.{Methods, Requests}
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

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. Production gets
    # all three from `seed_gl.exs`; a test that mints an institution inline has
    # to supply them. See `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(sys_id, bank_id)
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Funding", last_name: "Test#{n}"})
      |> Repo.insert!()

    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id, name: "Funding Wallet",
        sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    account
    |> WalletAccount.changeset(%{velocity_limits: limits})
    |> Repo.update!()
  end

  defp wallet_method_fixture do
    n = System.unique_integer([:positive])

    {:ok, method} =
      Methods.create(%{
        "name" => "Wallet Step-Up #{n}", "title" => "Wallet Step-Up KYC",
        "product_type" => "WALLET", "status" => "active", "fields" => []
      })

    method
  end

  test "a funding under the configured limit succeeds normally" do
    account = wallet_fixture(%{"DAILY" => %{"amount" => 1000}})

    assert {:ok, %{funding: funding}} =
             WalletFundingCommand.fund(%{
               wallet_account_id: account.wallet_account_id, amount: D.new("500"),
               channel: "ADMIN_MANUAL", posted_by: "test"
             })

    assert funding.wallet_account_id == account.wallet_account_id
    assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new("500"))
  end

  test "a breach declines the funding, leaves the balance untouched, and records a limit_step_up_triggered event" do
    account = wallet_fixture(%{"DAILY" => %{"count" => 0}})

    assert {:error, {:step_up_required, %{type: "DAILY_COUNT"}}} =
             WalletFundingCommand.fund(%{
               wallet_account_id: account.wallet_account_id, amount: D.new("50"),
               channel: "ADMIN_MANUAL", posted_by: "test"
             })

    assert D.equal?(Repo.get!(WalletAccount, account.wallet_account_id).available_balance, D.new(0))
    refute Repo.get_by(WalletFunding, wallet_account_id: account.wallet_account_id)

    [event] = WalletNonMonetaryEvent.history_for(account.wallet_account_id)
    assert event.event_type == "limit_step_up_triggered"
    assert event.new_value["limit_type"] == "DAILY_COUNT"
    assert event.operator_role == "SYSTEM"
  end

  test "a breach auto-creates a step-up WALLET KYC request for the account's customer" do
    wallet_method_fixture()
    account = wallet_fixture(%{"DAILY" => %{"count" => 0}})

    assert {:error, {:step_up_required, _}} =
             WalletFundingCommand.fund(%{
               wallet_account_id: account.wallet_account_id, amount: D.new("50"),
               channel: "ADMIN_MANUAL", posted_by: "test"
             })

    requests = Requests.list(%{"customer_id" => account.customer_id, "product_type" => "WALLET"})
    assert [request] = requests
    assert request.status == "submitted"
  end

  test "repeated breaches while a step-up request is pending don't create duplicate requests" do
    wallet_method_fixture()
    account = wallet_fixture(%{"DAILY" => %{"count" => 0}})

    attrs = %{wallet_account_id: account.wallet_account_id, amount: D.new("50"), channel: "ADMIN_MANUAL", posted_by: "test"}
    assert {:error, {:step_up_required, _}} = WalletFundingCommand.fund(attrs)
    assert {:error, {:step_up_required, _}} = WalletFundingCommand.fund(attrs)

    requests = Requests.list(%{"customer_id" => account.customer_id, "product_type" => "WALLET"})
    assert length(requests) == 1
  end

  test "a breach with no WALLET KYC method configured still declines funding, without crashing" do
    account = wallet_fixture(%{"DAILY" => %{"count" => 0}})

    assert {:error, {:step_up_required, _}} =
             WalletFundingCommand.fund(%{
               wallet_account_id: account.wallet_account_id, amount: D.new("50"),
               channel: "ADMIN_MANUAL", posted_by: "test"
             })

    assert Requests.list(%{"customer_id" => account.customer_id, "product_type" => "WALLET"}) == []
  end
end
