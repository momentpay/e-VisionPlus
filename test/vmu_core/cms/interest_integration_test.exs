defmodule VmuCore.CMS.InterestIntegrationTest do
  use ExUnit.Case, async: false

  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.InterestEngine,
                 CMS.StatementGenerator, CMS.InternalGlPoster}
  alias Decimal, as: D

  @account_id "cms-int-test-001"
  @sys_id "SYS01"
  @bank_id "BANK01"
  @logo_id "LOGO01"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    Repo.insert!(%Account{
      account_id:     @account_id,
      sys_id:         @sys_id,
      bank_id:        @bank_id,
      logo_id:        @logo_id,
      block_id:       "BLK01",
      customer_id:    "cust-001",
      credit_limit:   D.new("10000.00"),
      open_to_buy:    D.new("8000.00"),
      account_status: "ACTIVE",
      cycle_code:     25
    })

    :ok
  end

  describe "ADB interest calculation" do
    test "accrues interest correctly on retail balance" do
      apr = D.new("24.00")
      days_in_cycle = 30

      # Simulate 30 days of $1000 retail balance
      daily_balances = for i <- 0..(days_in_cycle - 1) do
        {Date.add(Date.utc_today(), -i), D.new("1000.00")}
      end

      result = InterestEngine.calculate(daily_balances, [], apr, days_in_cycle, false)

      # Expected: 1000 × (24%/365) × 30 ≈ 19.73
      assert D.compare(result.retail, D.new("0")) == :gt
      assert D.compare(result.retail, D.new("25")) == :lt
    end

    test "grace period suppresses retail interest when full payment received" do
      apr = D.new("24.00")
      days = 30

      daily_balances = for i <- 0..(days - 1), do: {Date.add(Date.utc_today(), -i), D.new("500.00")}
      result = InterestEngine.calculate(daily_balances, [], apr, days, _grace = true)

      assert D.compare(result.retail, D.new("0")) == :eq
    end
  end

  describe "StatementGenerator.generate/3" do
    test "persists statement balance and minimum payment" do
      today = Date.utc_today()

      Repo.insert!(%BalanceBucket{
        account_id:       @account_id,
        balance_date:     today,
        retail_balance:   D.new("2000.00"),
        cash_balance:     D.new("0"),
        accrued_interest: D.new("0"),
        unpaid_fees:      D.new("0"),
        statement_balance: D.new("0"),
        minimum_payment:   D.new("0")
      })

      {:ok, stmt} = StatementGenerator.generate(@account_id, today, apr_percentage: D.new("24.00"))

      assert D.compare(stmt.statement_balance, D.new("0")) == :gt
      assert D.compare(stmt.minimum_payment, D.new("0")) == :gt
    end
  end

  describe "InternalGlPoster idempotency" do
    test "second posting with same idempotency_key returns :duplicate" do
      attrs = %{
        account_id:       @account_id,
        idempotency_key:  "test-idem-001",
        transaction_code: "TEST",
        dr_amount:        D.new("100"),
        cr_amount:        D.new("100"),
        gl_account_dr:    "1001",
        gl_account_cr:    "2001",
        posting_date:     Date.utc_today(),
        value_date:       Date.utc_today(),
        narrative:        "Test entry"
      }

      assert {:ok, _} = InternalGlPoster.post(attrs)
      assert {:error, :duplicate} = InternalGlPoster.post(attrs)
    end
  end
end
