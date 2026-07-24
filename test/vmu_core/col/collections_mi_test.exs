defmodule VmuCore.COL.CollectionsMiTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. `roll_cure_rates/2` is tested
  against directly-inserted `DpdBucketHistory` rows (that schema is a
  plain changeset insert with no logic of its own to exercise — the real
  new logic under test is `CollectionsMi`'s cohort/roll/cure queries).
  `promise_kept_rate/2` and `recovery_rate/2` go through the real
  `PromiseVerification`/`WriteOffProcessor`/`ChargeOffRecovery` flows.
  Same fixture pattern as `ColComponentTest`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, BalanceBucket, ChargeOffRecovery}
  alias VmuCore.COL.{CollectionCase, CollectionsMi, DpdBucketHistory, PromiseVerification, WriteOffProcessor}
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

  defp account_fixture do
    {sys_id, bank_id, logo_id, block_id} = parameter_hierarchy_fixture()
    n = System.unique_integer([:positive])

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Mi", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "MI-TEST-#{n}"
      })
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "mi-test-pan-#{n}", last_four: "6666",
        expiry_date: "1230", credit_limit: D.new("10000.00"), open_to_buy: D.new("10000.00")
      })
      |> Repo.insert!()

    %BalanceBucket{}
    |> BalanceBucket.changeset(%{account_id: account.account_id, balance_date: Date.utc_today()})
    |> Repo.insert!()

    account
  end

  defp case_fixture(account, overrides \\ %{}) do
    %CollectionCase{}
    |> CollectionCase.changeset(Map.merge(%{
      account_id: account.account_id, dpd_bucket: 90,
      outstanding_amount: D.new("500.00"), status: "OPEN"
    }, overrides))
    |> Repo.insert!()
  end

  defp bucket_transition(account, eod_date, old_bucket, new_bucket) do
    %DpdBucketHistory{}
    |> DpdBucketHistory.changeset(%{
      account_id: account.account_id, eod_date: eod_date,
      old_bucket: old_bucket, new_bucket: new_bucket
    })
    |> Repo.insert!()
  end

  describe "roll_cure_rates/2" do
    test "an empty history for the window returns nil rates, not zero" do
      assert [%{bucket: 30, cohort_size: 0, roll_rate: nil, cure_rate: nil} | _] =
               CollectionsMi.roll_cure_rates(~D[2026-01-01], ~D[2026-01-31])
    end

    test "computes roll rate and cure rate for a mixed cohort at 30 DPD" do
      base = ~D[2026-06-01]

      rolled_acct = account_fixture()
      cured_acct = account_fixture()
      stayed_acct = account_fixture()

      # All three arrive at 30 DPD on the same day, inside the window.
      bucket_transition(rolled_acct, base, 0, 30)
      bucket_transition(cured_acct, base, 0, 30)
      bucket_transition(stayed_acct, base, 0, 30)

      # rolled_acct gets worse later in the window.
      bucket_transition(rolled_acct, Date.add(base, 10), 30, 60)
      # cured_acct pays up and returns to 0 later in the window.
      bucket_transition(cured_acct, Date.add(base, 15), 30, 0)
      # stayed_acct has no further transition in the window at all.

      [b30 | _] = CollectionsMi.roll_cure_rates(base, Date.add(base, 30))

      assert b30.bucket == 30
      assert b30.cohort_size == 3
      assert b30.rolled == 1
      assert b30.cured == 1
      assert D.equal?(b30.roll_rate, D.new("33.33"))
      assert D.equal?(b30.cure_rate, D.new("33.33"))
    end

    test "a later transition outside the window doesn't count" do
      base = ~D[2026-06-01]
      account = account_fixture()

      bucket_transition(account, base, 0, 30)
      # Rolls to 60, but after the window closes.
      bucket_transition(account, Date.add(base, 40), 30, 60)

      [b30 | _] = CollectionsMi.roll_cure_rates(base, Date.add(base, 30))

      assert b30.cohort_size == 1
      assert b30.rolled == 0
      assert D.equal?(b30.roll_rate, D.new("0.00"))
    end
  end

  describe "promise_kept_rate/2" do
    test "counts kept vs broken vs pending within the window, rate over resolved only" do
      today = Date.utc_today()

      kept_account = account_fixture()
      kept_case = case_fixture(kept_account)
      {:ok, _} = PromiseVerification.log_promise(kept_case.case_id, D.new("100.00"), today)
      # A real payment >= the promised amount, posted directly to the ledger via GL.
      VmuCore.CMS.InternalGlPoster.post(%{
        account_id: kept_account.account_id, idempotency_key: "mi-test-kept-#{System.unique_integer([:positive])}",
        transaction_code: "PAYMENT", dr_amount: D.new("100.00"), cr_amount: D.new("100.00"),
        gl_account_dr: "9001", gl_account_cr: "1001", posting_date: today, value_date: today
      })
      {:ok, :kept} = PromiseVerification.verify_case(Repo.get!(CollectionCase, kept_case.case_id), today)

      broken_account = account_fixture()
      broken_case = case_fixture(broken_account)
      {:ok, _} = PromiseVerification.log_promise(broken_case.case_id, D.new("100.00"), today)
      {:ok, :broken} = PromiseVerification.verify_case(Repo.get!(CollectionCase, broken_case.case_id), today)

      pending_account = account_fixture()
      pending_case = case_fixture(pending_account)
      {:ok, _} = PromiseVerification.log_promise(pending_case.case_id, D.new("50.00"), Date.add(today, 30))

      result = CollectionsMi.promise_kept_rate(Date.add(today, -1), Date.add(today, 1))

      assert result.kept >= 1
      assert result.broken >= 1
      # rate is over kept+broken only (pending isn't resolved yet)
      assert D.compare(result.rate, D.new(0)) == :gt
    end
  end

  describe "recovery_rate/2" do
    test "sums write_off_amount vs real recovered ledger entries for the cohort" do
      account = account_fixture()

      account
      |> Account.changeset(%{account_status: "DELINQUENT", open_to_buy: D.new("2000.00")})
      |> Repo.update!()

      case_fixture(account, %{status: "WRITTEN_OFF", dpd_bucket: 180})

      {:ok, %{write_off_amount: written_off}} = WriteOffProcessor.write_off(account.account_id)

      # Sync the case's own write_off_amount/date the way CollectionQueueJob's
      # WriteOffCommand path would — WriteOffProcessor only touches the account.
      Repo.get_by!(CollectionCase, account_id: account.account_id)
      |> CollectionCase.changeset(%{write_off_date: Date.utc_today(), write_off_amount: written_off})
      |> Repo.update!()

      partial_recovery = D.div(written_off, D.new(2))
      {:ok, _} = ChargeOffRecovery.record_recovery(account.account_id, partial_recovery, "mi-test-recovery-#{System.unique_integer([:positive])}")

      result = CollectionsMi.recovery_rate(Date.add(Date.utc_today(), -1), Date.add(Date.utc_today(), 1))

      assert result.cohort_size >= 1
      assert D.compare(result.written_off_total, D.new(0)) == :gt
      assert D.compare(result.recovered_total, D.new(0)) == :gt
      assert D.compare(result.rate, D.new(0)) == :gt
      assert D.compare(result.rate, D.new(100)) != :gt
    end
  end
end
