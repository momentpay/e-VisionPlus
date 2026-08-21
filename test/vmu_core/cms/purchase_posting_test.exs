defmodule VmuCore.CMS.PurchasePostingTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Self-contained parameter
  hierarchy + account fixtures (same pattern as the DPS/CycleResegmentation
  test suites).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, BalanceBucket, PurchasePosting, TransactionAllocation}
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

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"})
    |> Repo.insert!()

    %LogoParameter{}
    |> LogoParameter.changeset(%{
      sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"
    })
    |> Repo.insert!()

    %BlockParameter{}
    |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id})
    |> Repo.insert!()

    {sys_id, bank_id, logo_id, block_id}
  end

  defp account_with_bucket_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Purch", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "PURCH-TEST-#{n}"
      })
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "purch-test-pan-#{n}", last_four: "9999",
        expiry_date: "1230", credit_limit: D.new("10000.00")
      })
      |> Repo.insert!()

    %BalanceBucket{}
    |> BalanceBucket.changeset(%{account_id: account.account_id, balance_date: Date.utc_today()})
    |> Repo.insert!()

    account
  end

  describe "post/1" do
    test "creates a transaction allocation row and increments the bucket" do
      account = account_with_bucket_fixture()
      key = "settlement:test-#{System.unique_integer([:positive])}"

      assert {:ok, allocation} =
               PurchasePosting.post(%{
                 account_id: account.account_id,
                 amount: D.new("125.50"),
                 bucket_field: "retail_balance",
                 transaction_date: Date.utc_today(),
                 idempotency_key: key
               })

      assert allocation.original_amount == D.new("125.50")
      assert allocation.remaining_amount == D.new("125.50")
      assert allocation.status == "OUTSTANDING"

      bucket = Repo.get_by!(BalanceBucket, account_id: account.account_id)
      assert D.equal?(bucket.retail_balance, D.new("125.50"))
    end

    test "defaults to retail_balance when bucket_field is omitted" do
      account = account_with_bucket_fixture()
      key = "settlement:test-#{System.unique_integer([:positive])}"

      {:ok, allocation} =
        PurchasePosting.post(%{
          account_id: account.account_id,
          amount: D.new("50.00"),
          transaction_date: Date.utc_today(),
          idempotency_key: key
        })

      assert allocation.bucket_field == "retail_balance"
    end

    test "posts to cash_balance for a cash-advance" do
      account = account_with_bucket_fixture()
      key = "settlement:test-#{System.unique_integer([:positive])}"

      {:ok, _} =
        PurchasePosting.post(%{
          account_id: account.account_id,
          amount: D.new("300.00"),
          bucket_field: "cash_balance",
          transaction_date: Date.utc_today(),
          idempotency_key: key
        })

      bucket = Repo.get_by!(BalanceBucket, account_id: account.account_id)
      assert D.equal?(bucket.cash_balance, D.new("300.00"))
      assert D.equal?(bucket.retail_balance, D.new(0))
    end

    test "is idempotent on the same key — second call does not double-post" do
      account = account_with_bucket_fixture()
      key = "settlement:test-#{System.unique_integer([:positive])}"

      {:ok, first} =
        PurchasePosting.post(%{
          account_id: account.account_id, amount: D.new("100.00"),
          transaction_date: Date.utc_today(), idempotency_key: key
        })

      {:ok, second} =
        PurchasePosting.post(%{
          account_id: account.account_id, amount: D.new("100.00"),
          transaction_date: Date.utc_today(), idempotency_key: key
        })

      assert first.allocation_id == second.allocation_id

      bucket = Repo.get_by!(BalanceBucket, account_id: account.account_id)
      assert D.equal?(bucket.retail_balance, D.new("100.00"))
      assert Repo.aggregate(TransactionAllocation, :count) == 1
    end

    test "two different transactions accumulate on the bucket" do
      account = account_with_bucket_fixture()

      {:ok, _} =
        PurchasePosting.post(%{
          account_id: account.account_id, amount: D.new("40.00"),
          transaction_date: Date.utc_today(), idempotency_key: "settlement:a-#{System.unique_integer([:positive])}"
        })

      {:ok, _} =
        PurchasePosting.post(%{
          account_id: account.account_id, amount: D.new("60.00"),
          transaction_date: Date.utc_today(), idempotency_key: "settlement:b-#{System.unique_integer([:positive])}"
        })

      bucket = Repo.get_by!(BalanceBucket, account_id: account.account_id)
      assert D.equal?(bucket.retail_balance, D.new("100.00"))
    end
  end
end
