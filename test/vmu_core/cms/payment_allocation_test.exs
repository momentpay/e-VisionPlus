defmodule VmuCore.CMS.PaymentAllocationTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Same fixture pattern as
  `PurchasePostingTest`.
  """

  use ExUnit.Case, async: false

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, BalanceBucket, PaymentAllocation, PurchasePosting, TransactionAllocation}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, ModuleConfigWriter, SysParameter}
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
        sys_id: sys_id, bank_id: bank_id, first_name: "Alloc", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "ALLOC-TEST-#{n}"
      })
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "alloc-test-pan-#{n}", last_four: "9999",
        expiry_date: "1230", credit_limit: D.new("10000.00")
      })
      |> Repo.insert!()

    %BalanceBucket{}
    |> BalanceBucket.changeset(%{account_id: account.account_id, balance_date: Date.utc_today()})
    |> Repo.insert!()

    account
  end

  defp purchase(account, amount, date \\ Date.utc_today()) do
    {:ok, allocation} =
      PurchasePosting.post(%{
        account_id: account.account_id,
        amount: D.new(amount),
        transaction_date: date,
        idempotency_key: "settlement:#{System.unique_integer([:positive])}"
      })

    allocation
  end

  describe "allocate_payment/3 — fifo (default)" do
    test "pays off the oldest transaction first, fully, before touching the next" do
      account = account_with_bucket_fixture()
      oldest = purchase(account, "100.00", Date.add(Date.utc_today(), -10))
      newest = purchase(account, "100.00", Date.utc_today())

      {:ok, applied} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("150.00"))

      oldest_applied = Enum.find(applied, &(&1.allocation_id == oldest.allocation_id))
      newest_applied = Enum.find(applied, &(&1.allocation_id == newest.allocation_id))

      assert D.equal?(oldest_applied.applied, D.new("100.00"))
      assert D.equal?(newest_applied.applied, D.new("50.00"))

      oldest_reloaded = Repo.get!(TransactionAllocation, oldest.allocation_id)
      newest_reloaded = Repo.get!(TransactionAllocation, newest.allocation_id)
      assert oldest_reloaded.status == "PAID"
      assert newest_reloaded.status == "PARTIALLY_PAID"
      assert D.equal?(newest_reloaded.remaining_amount, D.new("50.00"))
    end
  end

  describe "allocate_payment/3 — lifo" do
    test "pays off the newest transaction first when configured lifo" do
      account = account_with_bucket_fixture()

      ModuleConfigWriter.put(
        "cms", "payment_allocation_method", "lifo",
        %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
      )

      oldest = purchase(account, "100.00", Date.add(Date.utc_today(), -10))
      newest = purchase(account, "100.00", Date.utc_today())

      {:ok, _applied} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("100.00"))

      assert Repo.get!(TransactionAllocation, newest.allocation_id).status == "PAID"
      assert Repo.get!(TransactionAllocation, oldest.allocation_id).status == "OUTSTANDING"
    end
  end

  describe "allocate_payment/3 — highest_amount_first" do
    test "pays off the largest outstanding transaction first" do
      account = account_with_bucket_fixture()

      ModuleConfigWriter.put(
        "cms", "payment_allocation_method", "highest_amount_first",
        %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
      )

      small = purchase(account, "20.00")
      large = purchase(account, "80.00")

      {:ok, _applied} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("80.00"))

      assert Repo.get!(TransactionAllocation, large.allocation_id).status == "PAID"
      assert Repo.get!(TransactionAllocation, small.allocation_id).status == "OUTSTANDING"
    end
  end

  describe "allocate_payment/3 — proportional" do
    test "spreads the payment pro-rata across every outstanding transaction" do
      account = account_with_bucket_fixture()

      ModuleConfigWriter.put(
        "cms", "payment_allocation_method", "proportional",
        %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
      )

      a = purchase(account, "100.00")
      b = purchase(account, "300.00")

      {:ok, applied} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("100.00"))

      a_applied = Enum.find(applied, &(&1.allocation_id == a.allocation_id)).applied
      b_applied = Enum.find(applied, &(&1.allocation_id == b.allocation_id)).applied

      # 1:3 ratio -> 25.00 / 75.00, and nothing is left unapplied
      assert D.equal?(a_applied, D.new("25.00"))
      assert D.equal?(b_applied, D.new("75.00"))
      assert D.equal?(D.add(a_applied, b_applied), D.new("100.00"))

      a_reloaded = Repo.get!(TransactionAllocation, a.allocation_id)
      b_reloaded = Repo.get!(TransactionAllocation, b.allocation_id)
      assert a_reloaded.status == "PARTIALLY_PAID"
      assert b_reloaded.status == "PARTIALLY_PAID"
    end
  end

  describe "allocate_payment/3 — disputed exclusion" do
    test "skips a disputed transaction by default" do
      account = account_with_bucket_fixture()
      disputed = purchase(account, "50.00", Date.add(Date.utc_today(), -5))
      clean = purchase(account, "50.00")

      Repo.update_all(
        from(a in TransactionAllocation, where: a.allocation_id == ^disputed.allocation_id),
        set: [disputed: true]
      )

      {:ok, applied} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("50.00"))

      assert [%{allocation_id: id}] = applied
      assert id == clean.allocation_id

      assert Repo.get!(TransactionAllocation, disputed.allocation_id).status == "OUTSTANDING"
      assert Repo.get!(TransactionAllocation, clean.allocation_id).status == "PAID"
    end

    test "includes disputed transactions when exclude_disputed_from_allocation is false" do
      account = account_with_bucket_fixture()

      ModuleConfigWriter.put(
        "cms", "exclude_disputed_from_allocation", false,
        %{scope_type: "bank", sys_id: account.sys_id, bank_id: account.bank_id}, nil
      )

      disputed = purchase(account, "50.00")

      Repo.update_all(
        from(a in TransactionAllocation, where: a.allocation_id == ^disputed.allocation_id),
        set: [disputed: true]
      )

      {:ok, applied} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("50.00"))

      assert [%{allocation_id: id}] = applied
      assert id == disputed.allocation_id
    end
  end

  describe "allocate_payment/3 — non-allocatable buckets and edge cases" do
    test "no-ops for a bucket with no transaction-level detail (e.g. unpaid_fees)" do
      account = account_with_bucket_fixture()
      assert {:ok, []} = PaymentAllocation.allocate_payment(account, :unpaid_fees, D.new("10.00"))
    end

    test "no-ops for a zero amount" do
      account = account_with_bucket_fixture()
      purchase(account, "50.00")
      assert {:ok, []} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("0.00"))
    end

    test "no-ops when nothing is outstanding" do
      account = account_with_bucket_fixture()
      assert {:ok, []} = PaymentAllocation.allocate_payment(account, :retail_balance, D.new("50.00"))
    end
  end
end
