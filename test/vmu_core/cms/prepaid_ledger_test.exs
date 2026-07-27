defmodule VmuCore.CMS.PrepaidLedgerTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 5
  (Prepaid, P1) — the stored-value ledger: derived balance, per-load
  expiry (FIFO soonest-expiring-first consumption), and reversal that
  restores exactly the loads a spend drew from.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{PrepaidAccountOpening, PrepaidLedger, PrepaidLedgerEntry}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp prepaid_account_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "606060", description: "test", product_type: "PREPAID"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Prepaid", last_name: "LedgerTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    account
  end

  describe "load/1 + balance/1" do
    test "a load increases the derived balance and posts a real GL entry" do
      account = prepaid_account_fixture()

      assert {:ok, %{load_entry: entry, ledger_gl_entry: gl}} =
               PrepaidLedger.load(%{
                 prepaid_account_id: account.prepaid_account_id, amount: D.new("200.00"),
                 channel: "ADMIN_MANUAL", posted_by: "operator1"
               })

      assert entry.entry_type == "LOAD"
      assert D.equal?(entry.remaining_amount, D.new("200.00"))
      assert gl.gl_account_dr == "1006"
      assert gl.gl_account_cr == "5002"

      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("200.00"))
    end

    test "multiple loads accumulate in the derived balance" do
      account = prepaid_account_fixture()

      {:ok, _} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})
      {:ok, _} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("150.00"))
    end

    test "external channel requires a reference" do
      account = prepaid_account_fixture()

      assert {:error, %Ecto.Changeset{}} =
               PrepaidLedger.load(%{
                 prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"),
                 channel: "CASH_DEPOSIT", posted_by: "op1"
               })

      assert {:ok, _} =
               PrepaidLedger.load(%{
                 prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"),
                 channel: "CASH_DEPOSIT", posted_by: "op1", external_reference: "CASHREF-1"
               })
    end
  end

  describe "spend/3" do
    test "spends against a single load, decrementing its remaining_amount" do
      account = prepaid_account_fixture()
      {:ok, _} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      assert {:ok, spend} = PrepaidLedger.spend(account.prepaid_account_id, D.new("30.00"))
      assert spend.entry_type == "SPEND"
      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("70.00"))
    end

    test "spend consumes soonest-expiring load first (FIFO by expiry_date)" do
      account = prepaid_account_fixture()
      today = Date.utc_today()

      {:ok, %{load_entry: far}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"),
          channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: Date.add(today, 365)})

      {:ok, %{load_entry: soon}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"),
          channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: Date.add(today, 10)})

      {:ok, spend} = PrepaidLedger.spend(account.prepaid_account_id, D.new("30.00"))

      assert [%{"load_entry_id" => id, "amount" => "30.00"}] = spend.consumed_from
      assert id == soon.id

      reloaded_soon = Repo.get!(PrepaidLedgerEntry, soon.id)
      reloaded_far = Repo.get!(PrepaidLedgerEntry, far.id)
      assert D.equal?(reloaded_soon.remaining_amount, D.new("20.00"))
      assert D.equal?(reloaded_far.remaining_amount, D.new("100.00"))
    end

    test "a spend spanning multiple loads records every load it drew from" do
      account = prepaid_account_fixture()
      today = Date.utc_today()

      {:ok, %{load_entry: load1}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("20.00"),
          channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: Date.add(today, 5)})

      {:ok, %{load_entry: load2}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"),
          channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: Date.add(today, 30)})

      {:ok, spend} = PrepaidLedger.spend(account.prepaid_account_id, D.new("35.00"))

      breakdown = Map.new(spend.consumed_from, fn %{"load_entry_id" => id, "amount" => amt} -> {id, amt} end)
      assert breakdown[load1.id] == "20.00"
      assert breakdown[load2.id] == "15.00"

      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("35.00"))
    end

    test "declines with :insufficient_funds and touches nothing when balance is too low" do
      account = prepaid_account_fixture()
      {:ok, _} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("10.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      assert {:error, :insufficient_funds} = PrepaidLedger.spend(account.prepaid_account_id, D.new("50.00"))
      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("10.00"))
    end

    test "an expired (non-ACTIVE) load is never consumed" do
      account = prepaid_account_fixture()

      {:ok, %{load_entry: expired}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      expired |> PrepaidLedgerEntry.changeset(%{status: "EXPIRED"}) |> Repo.update!()

      assert {:error, :insufficient_funds} = PrepaidLedger.spend(account.prepaid_account_id, D.new("10.00"))
    end

    test "rejects a suspended account" do
      account = prepaid_account_fixture()
      {:ok, _} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      account |> VmuCore.CMS.PrepaidAccount.changeset(%{status: "SUSPENDED"}) |> Repo.update!()

      assert {:error, :not_active} = PrepaidLedger.spend(account.prepaid_account_id, D.new("10.00"))
    end
  end

  describe "credit/1" do
    test "restores exactly the loads a spend drew from" do
      account = prepaid_account_fixture()
      today = Date.utc_today()

      {:ok, %{load_entry: load1}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("20.00"),
          channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: Date.add(today, 5)})

      {:ok, %{load_entry: load2}} =
        PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("50.00"),
          channel: "ADMIN_MANUAL", posted_by: "op1", expiry_date: Date.add(today, 30)})

      {:ok, spend} = PrepaidLedger.spend(account.prepaid_account_id, D.new("35.00"))
      assert :ok = PrepaidLedger.credit(spend.id)

      reloaded1 = Repo.get!(PrepaidLedgerEntry, load1.id)
      reloaded2 = Repo.get!(PrepaidLedgerEntry, load2.id)
      assert D.equal?(reloaded1.remaining_amount, D.new("20.00"))
      assert D.equal?(reloaded2.remaining_amount, D.new("50.00"))
      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("70.00"))
    end

    test "returns :not_found for an unknown entry" do
      assert {:error, :not_found} = PrepaidLedger.credit(Ecto.UUID.generate())
    end

    test "returns :not_a_spend_entry for a LOAD entry id" do
      account = prepaid_account_fixture()
      {:ok, %{load_entry: load}} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("10.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      assert {:error, :not_a_spend_entry} = PrepaidLedger.credit(load.id)
    end
  end

  describe "concurrent spends never oversell the balance" do
    test "5 concurrent 30.00 spends against a 100.00 balance approve at most 3" do
      account = prepaid_account_fixture()
      {:ok, _} = PrepaidLedger.load(%{prepaid_account_id: account.prepaid_account_id, amount: D.new("100.00"), channel: "ADMIN_MANUAL", posted_by: "op1"})

      test_pid = self()

      results =
        1..5
        |> Task.async_stream(fn _ ->
          Ecto.Adapters.SQL.Sandbox.allow(Repo, test_pid, self())
          PrepaidLedger.spend(account.prepaid_account_id, D.new("30.00"))
        end, max_concurrency: 5)
        |> Enum.map(fn {:ok, result} -> result end)

      approved = Enum.count(results, &match?({:ok, _}, &1))
      declined = Enum.count(results, &match?({:error, :insufficient_funds}, &1))

      assert approved == 3
      assert declined == 2
      assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("10.00"))
    end
  end
end
