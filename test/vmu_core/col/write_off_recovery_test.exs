defmodule VmuCore.COL.WriteOffRecoveryTest do
  @moduledoc """
  COL bucket routing, write-off and recovery.

  Rewritten 2026-08-04. The previous version tested an interface that was never
  built: it called `VmuCore.COL.QueueRouter.route_account/1` and aliased
  `VmuCore.COL.CollectionAccount`, neither of which exists, and two of its four
  tests only asserted `function_exported?/3` on `COL.WriteOffEngine` and
  `COL.RecoveryEngine` — also non-existent. Those were placeholders written
  against a planned design; COL was implemented differently.

  The capabilities are real, just named differently:

  | Speculative | Actual |
  |---|---|
  | `COL.QueueRouter.route_account/1` | `COL.BucketStrategy.step_for_dpd/2` |
  | `COL.WriteOffEngine.execute/2` | `COL.WriteOffProcessor.write_off/1` |
  | `COL.RecoveryEngine.post_recovery/3` | `COL.WriteOffProcessor.post_recovery/3` |
  """
  use ExUnit.Case, async: false

  alias VmuCore.GLFixtures
  alias VmuCore.{Repo, CMS.Account, COL.BucketStrategy, COL.WriteOffProcessor}
  alias Decimal, as: D

  @sys_id "SYS2"
  @bank_id "BNK2"
  @logo_id "LGO2"
  @block_id "BLK2"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. See
    # `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(@sys_id, @bank_id)
    :ok
  end

  defp account_fixture(attrs \\ %{}) do
    defaults = %{
      account_id: Ecto.UUID.generate(),
      customer_id: Ecto.UUID.generate(),
      sys_id: @sys_id,
      bank_id: @bank_id,
      logo_id: @logo_id,
      block_id: @block_id,
      pan_token: "tok_#{System.unique_integer([:positive])}",
      last_four: "4242",
      expiry_date: "1229",
      credit_limit: D.new("10000.00"),
      open_to_buy: D.new("4000.00"),
      cycle_code: 25,
      account_status: "DELINQUENT",
      delinquency_bucket: 180
    }

    Repo.insert!(struct(Account, Map.merge(defaults, attrs)))
  end

  describe "bucket routing (BucketStrategy.step_for_dpd/2)" do
    test "an account below the first rung is in no collections queue" do
      account = account_fixture(%{account_status: "ACTIVE", delinquency_bucket: 0})

      # The ladder starts at day 30 — there is no continuous day counter here,
      # only the 30-day bucket jumps AgeBucketsJob produces.
      assert BucketStrategy.step_for_dpd(account, 0) == nil
    end

    test "picks the largest rung at or below the account's DPD" do
      account = account_fixture()

      assert %{"day" => 30, "queue" => "EARLY_COLLECTIONS"} =
               BucketStrategy.step_for_dpd(account, 30)

      assert %{"day" => 60, "queue" => "COLLECTIONS"} = BucketStrategy.step_for_dpd(account, 60)

      assert %{"day" => 90, "queue" => "SENIOR_COLLECTIONS"} =
               BucketStrategy.step_for_dpd(account, 90)
    end

    test "a DPD between rungs falls back to the lower rung, never the higher" do
      account = account_fixture()

      # 59 days must not be treated as 60 — escalating a customer early is a
      # real customer-facing error, not a rounding detail.
      assert %{"day" => 30} = BucketStrategy.step_for_dpd(account, 59)
    end

    test "the deepest bucket routes to the external agency" do
      account = account_fixture()

      assert %{"queue" => "EXTERNAL_AGENCY"} = BucketStrategy.step_for_dpd(account, 180)
    end
  end

  describe "write-off (WriteOffProcessor.write_off/1)" do
    test "writes off the drawn balance and reports the amount" do
      account = account_fixture(%{credit_limit: D.new("10000.00"), open_to_buy: D.new("4000.00")})

      assert {:ok, %{write_off_amount: amount}} = WriteOffProcessor.write_off(account.account_id)

      # Drawn balance = credit_limit - open_to_buy
      assert D.equal?(amount, D.new("6000.00"))
    end

    test "refuses an account that is not delinquent" do
      account = account_fixture(%{account_status: "ACTIVE"})

      assert {:error, :account_not_eligible} = WriteOffProcessor.write_off(account.account_id)
    end

    test "refuses an account with nothing drawn" do
      account = account_fixture(%{credit_limit: D.new("5000.00"), open_to_buy: D.new("5000.00")})

      assert {:error, :zero_balance} = WriteOffProcessor.write_off(account.account_id)
    end
  end

  describe "recovery (WriteOffProcessor.post_recovery/3)" do
    test "posts to recovery income without reversing the write-off" do
      account = account_fixture()
      ref = "REC-#{System.unique_integer([:positive])}"

      assert {:ok, entry} =
               WriteOffProcessor.post_recovery(account.account_id, D.new("750.00"), ref)

      # 3001 Payment/Adjustment Clearing -> 4004 Recovery Income. A recovery is
      # income; it does not reverse the charge-off, so the receivable stays
      # written off.
      assert entry.dr_gl_account == "3001"
      assert entry.cr_gl_account == "4004"
      assert D.equal?(entry.amount, D.new("750.00"))
    end

    test "is idempotent on the source reference" do
      account = account_fixture()
      ref = "REC-#{System.unique_integer([:positive])}"

      assert {:ok, _} = WriteOffProcessor.post_recovery(account.account_id, D.new("100.00"), ref)

      assert {:error, :duplicate} =
               WriteOffProcessor.post_recovery(account.account_id, D.new("100.00"), ref)
    end
  end
end
