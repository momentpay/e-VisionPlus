defmodule VmuCore.CMS.InterestIntegrationTest do
  use ExUnit.Case, async: false

  alias VmuCore.GLFixtures
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.InterestEngine,
                 CMS.StatementGenerator, CMS.InternalGlPoster}
  alias Decimal, as: D

  # `cms_accounts.account_id` and `.customer_id` are uuid columns. These were
  # plain strings ("cms-int-test-001"), which Ecto rejected at insert with
  # `does not match type :binary_id`, so every test in this file failed in
  # setup. Fixed 2026-08-04.
  @account_id "11111111-1111-4111-8111-111111111111"
  @customer_id "22222222-2222-4222-8222-222222222222"
  # sys/bank/logo/block ids are varchar(4) across the parameter cascade —
  # "SYS01"/"BANK01"/"LOGO01" overflowed and raised
  # `value too long for type character varying(4)` on insert.
  @sys_id "SYS1"
  @bank_id "BNK1"
  @logo_id "LGO1"
  @block_id "BLK1"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. See
    # `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(@sys_id, @bank_id)

    Repo.insert!(%Account{
      account_id:     @account_id,
      sys_id:         @sys_id,
      bank_id:        @bank_id,
      logo_id:        @logo_id,
      block_id:       @block_id,
      customer_id:    @customer_id,
      # pan_token / last_four / expiry_date are NOT NULL on cms_accounts —
      # the fixture predates those columns.
      pan_token:      "tok_interest_integration_test",
      last_four:      "4242",
      expiry_date:    "1229",
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

      # calculate/6 is (retail_daily, cash_daily, purchase_apr, cash_apr,
      # days_in_cycle, grace_applies). The previous call passed days_in_cycle
      # as cash_apr and `false` as days_in_cycle.
      result = InterestEngine.calculate(daily_balances, [], apr, apr, days_in_cycle, false)

      # Expected: 1000 × (24%/365) × 30 ≈ 19.73
      assert D.compare(result.retail_interest, D.new("0")) == :gt
      assert D.compare(result.retail_interest, D.new("25")) == :lt
    end

    test "grace period suppresses retail interest when full payment received" do
      apr = D.new("24.00")
      days = 30

      daily_balances = for i <- 0..(days - 1), do: {Date.add(Date.utc_today(), -i), D.new("500.00")}
      result = InterestEngine.calculate(daily_balances, [], apr, apr, days, _grace = true)

      assert D.compare(result.retail_interest, D.new("0")) == :eq
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
        # Validated against LedgerEntry's fixed list — "TEST" is not a member,
        # so the changeset was invalid and post/1 never reached the duplicate
        # check this test exists to exercise.
        transaction_code: "PURCHASE",
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
