defmodule VmuCore.LMS.ClawbackTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Covers FR-LMS-012 (reversal-aware
  accrual / points clawback on a won chargeback) — genuinely new work, not
  a re-port; neither copy of this codebase ever built it.

  Also exercises the real earn pipeline through a genuine
  `TRAMS.ClearingRecord` (not a synthetic integer id) — this is what
  surfaced the `source_clearing_id` bigint-vs-uuid type mismatch fixed in
  migration `20260724120001_...`, confirming the fix actually works end
  to end, not just that the schema compiles.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account, as: CmsAccount
  alias VmuCore.LMS.{Account, Clawback, Enrollment, Group, Plan, PointsEngine, PointsLedger,
                     RateTier, Scheme}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias VmuCore.TRAMS.ClearingRecord
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

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
        sys_id: sys_id, bank_id: bank_id, first_name: "Claw", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "CLAW-TEST-#{n}"
      })
      |> Repo.insert!()

    %CmsAccount{}
    |> CmsAccount.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "claw-test-pan-#{n}", last_four: "3333",
      expiry_date: "1230", credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  defp scheme_fixture do
    n = System.unique_integer([:positive])

    %Scheme{}
    |> Scheme.changeset(%{
      scheme_code: "S#{rem(n, 10000)}", scheme_name: "Test Scheme #{n}",
      org_id: n, currency: "AED", warehouse_days: 0
    })
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp group_fixture(scheme) do
    n = System.unique_integer([:positive])

    %Group{inserted_at: now()}
    |> Group.changeset(%{
      scheme_id: scheme.id, group_code: "GRP#{n}", group_type: "DEFAULT",
      group_name: "Test Group #{n}"
    })
    |> Repo.insert!()
  end

  defp plan_fixture(group) do
    %Plan{inserted_at: now()}
    |> Plan.changeset(%{group_id: group.id, plan_type: "BASE", effective_from: ~D[2020-01-01]})
    |> Repo.insert!()
  end

  defp rate_tier_fixture(plan) do
    %RateTier{inserted_at: now()}
    |> RateTier.changeset(%{
      plan_id: plan.id, tier_order: 1, min_amount: D.new("0"),
      points_per_unit: D.new("1"), min_qualifying_amount: D.new("0.01")
    })
    |> Repo.insert!()
  end

  # Real chain including a genuine TRAMS.ClearingRecord — earns points
  # through the actual PointsEngine.process_transaction/2 path a real
  # PointsCalculationJob run would take, not a synthetic clearing id.
  defp earn_via_real_clearing_record(amount) do
    scheme = scheme_fixture()
    group = group_fixture(scheme)
    plan = plan_fixture(group)
    rate_tier_fixture(plan)

    cms_account = cms_account_fixture()
    {:ok, lms_account} = Enrollment.enroll(cms_account.account_id, scheme.id)

    trams_transaction_id = Ecto.UUID.generate()

    clearing =
      %ClearingRecord{}
      |> ClearingRecord.changeset(%{
        account_id: cms_account.account_id, network: "VI", file_name: "test.ipm",
        record_type: "SALE", transaction_date: Date.utc_today(), amount: D.new(amount),
        currency: "AED", match_status: "MATCHED", matched_transaction_id: trams_transaction_id
      })
      |> Repo.insert!()

    PointsEngine.process_transaction(cms_account.account_id, %{
      amount: amount, transaction_date: Date.utc_today(),
      merchant_id: nil, clearing_record_id: clearing.clearing_id
    })

    {Repo.get!(Account, lms_account.id), trams_transaction_id, clearing}
  end

  describe "claw_back_transaction/1" do
    test "claws back the real points earned through a genuine ClearingRecord (proves the source_clearing_id fix works end to end)" do
      {account, trams_transaction_id, clearing} = earn_via_real_clearing_record("60.00")

      assert D.equal?(account.points_balance, D.new("60"))
      assert D.equal?(account.open_to_redeem, D.new("60"))

      entry = Repo.get_by!(PointsLedger, source_clearing_id: clearing.clearing_id)
      assert entry.warehouse_state == "ACTIVE"

      assert {:ok, %{clawed_back: 1, already_spent: 0}} = Clawback.claw_back_transaction(trams_transaction_id)

      after_clawback = Repo.get!(Account, account.id)
      assert D.equal?(after_clawback.points_balance, D.new("0"))
      assert D.equal?(after_clawback.open_to_redeem, D.new("0"))

      original_entry = Repo.get!(PointsLedger, entry.id)
      assert original_entry.warehouse_state == "HISTORY"

      clawback_entry = Repo.get_by!(PointsLedger, transaction_type: "CLAWBACK", lms_account_id: account.id)
      assert D.equal?(clawback_entry.points_amount, D.new("-60"))
    end

    test "a transaction that never earned any points is a clean no-op" do
      assert {:ok, %{clawed_back: 0, already_spent: 0}} = Clawback.claw_back_transaction(Ecto.UUID.generate())
    end

    test "already-redeemed points are not clawed back, and the caller can see that" do
      {account, trams_transaction_id, _clearing} = earn_via_real_clearing_record("100.00")

      {:ok, _} = VmuCore.LMS.RedemptionProcessor.redeem(account.id, D.new("100"))

      assert {:ok, %{clawed_back: 0, already_spent: 1}} = Clawback.claw_back_transaction(trams_transaction_id)

      unchanged = Repo.get!(Account, account.id)
      assert D.equal?(unchanged.open_to_redeem, D.new("0"))
    end
  end

  describe "DPS chargeback-win hook" do
    test "Dispute.transition/2 to CLOSED_WIN claws back points on the linked transaction" do
      {account, trams_transaction_id, _clearing} = earn_via_real_clearing_record("25.00")
      cms_account = cms_account_fixture()

      # Inserted directly rather than via Dispute.file/1 — under this
      # project's Oban testing: :inline config, file/1's 120-day chargeback
      # DeadlineJob runs synchronously on insert and would auto-cascade the
      # dispute through the whole lifecycle before this test's own
      # assertions run (a known, separately-documented testing gotcha, not
      # something to work around by changing the shared Oban test config).
      dispute =
        %VmuCore.DPS.Dispute{}
        |> VmuCore.DPS.Dispute.changeset(%{
          account_id: cms_account.account_id, trams_transaction_id: trams_transaction_id,
          transaction_date: Date.add(Date.utc_today(), -5), dispute_amount: D.new("25.00"),
          reason_code: "4853", network: "MC", status: "CHARGEBACK_FILED"
        })
        |> Repo.insert!()

      assert {:ok, _} = VmuCore.DPS.Dispute.transition(dispute.dispute_id, "CLOSED_WIN")

      after_win = Repo.get!(Account, account.id)
      assert D.equal?(after_win.open_to_redeem, D.new("0"))
    end
  end
end
