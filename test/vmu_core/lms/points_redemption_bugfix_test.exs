defmodule VmuCore.LMS.PointsRedemptionBugfixTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers the LMS-P1 fix chain
  (2026-07-11) ported back from Avenza on 2026-07-24 — see
  `docs/lms/LMS_Gap_Implementation_Tracker.md`. Before this port,
  standalone vmu_core's committed `RedemptionProcessor.redeem/3`
  unconditionally zeroed `open_to_redeem` after every redemption (comment
  claimed "recalculated nightly" — no such job existed), permanently
  locking any account out of redeeming again after its first redemption;
  `PointsExpiryJob` never released expired points from `open_to_redeem`
  either. Both are exercised here against a real Scheme→Group→Plan→
  RateTier→Enrollment chain, not the pre-existing (separately broken,
  unrelated, `entry_type`-field) `points_lifecycle_test.exs`.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account, as: CmsAccount
  alias VmuCore.LMS.{Account, Enrollment, Group, Plan, PointsEngine, PointsLedger,
                     RateTier, RedemptionProcessor, Scheme}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # lms_accounts.ar_account_id has a real FK to cms_accounts.account_id —
  # needs a genuine CMS account, not just a random UUID.
  defp cms_account_fixture do
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

    customer =
      %Customer{}
      |> Customer.changeset(%{
        sys_id: sys_id, bank_id: bank_id, first_name: "Lms", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "LMS-TEST-#{n}"
      })
      |> Repo.insert!()

    %CmsAccount{}
    |> CmsAccount.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "lms-test-pan-#{n}", last_four: "4444",
      expiry_date: "1230", credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  defp scheme_fixture(overrides \\ %{}) do
    n = System.unique_integer([:positive])

    %Scheme{}
    |> Scheme.changeset(Map.merge(%{
      scheme_code: "S#{rem(n, 10000)}", scheme_name: "Test Scheme #{n}",
      org_id: n, currency: "AED", warehouse_days: 0
    }, overrides))
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp group_fixture(scheme, type \\ "DEFAULT") do
    n = System.unique_integer([:positive])

    %Group{inserted_at: now()}
    |> Group.changeset(%{
      scheme_id: scheme.id, group_code: "GRP#{n}", group_type: type,
      group_name: "Test Group #{n}"
    })
    |> Repo.insert!()
  end

  defp plan_fixture(group, overrides \\ %{}) do
    %Plan{inserted_at: now()}
    |> Plan.changeset(Map.merge(%{
      group_id: group.id, plan_type: "BASE", effective_from: ~D[2020-01-01]
    }, overrides))
    |> Repo.insert!()
  end

  defp rate_tier_fixture(plan, overrides \\ %{}) do
    %RateTier{inserted_at: now()}
    |> RateTier.changeset(Map.merge(%{
      plan_id: plan.id, tier_order: 1, min_amount: D.new("0"),
      points_per_unit: D.new("1"), min_qualifying_amount: D.new("0.01")
    }, overrides))
    |> Repo.insert!()
  end

  # Full real chain: scheme -> default group -> base plan -> rate tier -> enrollment.
  # 1 point per currency unit, immediate ACTIVE (warehouse_days: 0).
  defp enrolled_account_fixture(scheme_overrides \\ %{}) do
    scheme = scheme_fixture(scheme_overrides)
    group = group_fixture(scheme, "DEFAULT")
    plan = plan_fixture(group)
    rate_tier_fixture(plan)

    cms_account = cms_account_fixture()
    ar_account_id = cms_account.account_id
    {:ok, account} = Enrollment.enroll(ar_account_id, scheme.id)
    {account, ar_account_id}
  end

  defp earn(account, ar_account_id, amount, clearing_id \\ nil) do
    PointsEngine.process_transaction(ar_account_id, %{
      amount: amount, transaction_date: Date.utc_today(),
      merchant_id: nil, clearing_record_id: clearing_id || Ecto.UUID.generate()
    })

    Repo.get!(Account, account.id)
  end

  describe "redemption no longer permanently locks the account (LMS-P1.3)" do
    test "a second redemption after the first succeeds against the real remaining balance" do
      {account, ar_account_id} = enrolled_account_fixture()
      account = earn(account, ar_account_id, "150.00")

      assert D.equal?(account.open_to_redeem, D.new("150"))

      {:ok, _redemption1} = RedemptionProcessor.redeem(account.id, D.new("100"))

      after_first = Repo.get!(Account, account.id)
      # The bug: this used to be forced to 0 regardless of real remaining balance.
      assert D.equal?(after_first.open_to_redeem, D.new("50"))

      assert {:ok, _redemption2} = RedemptionProcessor.redeem(account.id, D.new("30"))

      after_second = Repo.get!(Account, account.id)
      assert D.equal?(after_second.open_to_redeem, D.new("20"))
    end

    test "redeeming more than what's left is still correctly rejected" do
      {account, ar_account_id} = enrolled_account_fixture()
      account = earn(account, ar_account_id, "50.00")

      {:ok, _} = RedemptionProcessor.redeem(account.id, D.new("50"))

      assert {:error, :insufficient_open_to_redeem} = RedemptionProcessor.redeem(account.id, D.new("1"))
    end
  end

  describe "warehouse-state-aware earn (LMS-P1.2)" do
    test "immediate-earn scheme (warehouse_days: 0) makes points redeemable right away" do
      {account, ar_account_id} = enrolled_account_fixture(%{warehouse_days: 0})
      account = earn(account, ar_account_id, "40.00")

      assert D.equal?(account.points_balance, D.new("40"))
      assert D.equal?(account.open_to_redeem, D.new("40"))
    end

    test "warehousing scheme (warehouse_days > 0) posts points but does NOT make them redeemable yet" do
      {account, ar_account_id} = enrolled_account_fixture(%{warehouse_days: 30})
      account = earn(account, ar_account_id, "40.00")

      assert D.equal?(account.points_balance, D.new("40"))
      assert D.equal?(account.open_to_redeem, D.new("0"))

      ledger_entry = Repo.get_by!(PointsLedger, lms_account_id: account.id)
      assert ledger_entry.warehouse_state == "WAREHOUSE"
    end
  end

  describe "expiry releases open_to_redeem too (LMS-P1.4)" do
    test "PointsExpiryJob decrements open_to_redeem by the expired amount, not just points_balance" do
      {account, ar_account_id} = enrolled_account_fixture()
      account = earn(account, ar_account_id, "80.00")
      assert D.equal?(account.open_to_redeem, D.new("80"))

      # Backdate the ledger entry's expiry so the job picks it up.
      entry = Repo.get_by!(PointsLedger, lms_account_id: account.id)
      entry |> PointsLedger.changeset(%{expiry_date: Date.add(Date.utc_today(), -1)}) |> Repo.update!()

      assert :ok = VmuCore.LMS.Oban.PointsExpiryJob.perform(%Oban.Job{})

      after_expiry = Repo.get!(Account, account.id)
      assert D.equal?(after_expiry.points_balance, D.new("0"))
      # The bug: open_to_redeem used to stay at 80 forever, "redeemable"
      # against points that no longer exist.
      assert D.equal?(after_expiry.open_to_redeem, D.new("0"))

      expired_entry = Repo.get!(PointsLedger, entry.id)
      assert expired_entry.warehouse_state == "HISTORY"
    end
  end
end
