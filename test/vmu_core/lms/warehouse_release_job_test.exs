defmodule VmuCore.LMS.Oban.WarehouseReleaseJobTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Genuinely new work — closes the
  gap `LMS_Gap_Implementation_Tracker.md`'s LMS-P1 explicitly flagged as
  a known, un-fixed limitation: nothing ever promoted `WAREHOUSE`-state
  points to `ACTIVE`, so a scheme configured with `warehouse_days > 0`
  had its earned points permanently un-redeemable.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.Account, as: CmsAccount
  alias VmuCore.LMS.{Account, Enrollment, Group, Oban.WarehouseReleaseJob, Plan, PointsEngine,
                     PointsLedger, RateTier, Scheme}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
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
        sys_id: sys_id, bank_id: bank_id, first_name: "Wh", last_name: "Test#{n}",
        id_type: "PASSPORT", id_number: "WH-TEST-#{n}"
      })
      |> Repo.insert!()

    %CmsAccount{}
    |> CmsAccount.changeset(%{
      customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
      block_id: block_id, pan_token: "wh-test-pan-#{n}", last_four: "2222",
      expiry_date: "1230", credit_limit: D.new("10000.00")
    })
    |> Repo.insert!()
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp warehousing_account_fixture(warehouse_days) do
    n = System.unique_integer([:positive])

    scheme =
      %Scheme{}
      |> Scheme.changeset(%{
        scheme_code: "S#{rem(n, 10000)}", scheme_name: "Test Scheme #{n}",
        org_id: n, currency: "AED", warehouse_days: warehouse_days
      })
      |> Repo.insert!()

    group =
      %Group{inserted_at: now()}
      |> Group.changeset(%{scheme_id: scheme.id, group_code: "GRP#{n}", group_type: "DEFAULT", group_name: "G#{n}"})
      |> Repo.insert!()

    plan =
      %Plan{inserted_at: now()}
      |> Plan.changeset(%{group_id: group.id, plan_type: "BASE", effective_from: ~D[2020-01-01]})
      |> Repo.insert!()

    %RateTier{inserted_at: now()}
    |> RateTier.changeset(%{
      plan_id: plan.id, tier_order: 1, min_amount: D.new("0"),
      points_per_unit: D.new("1"), min_qualifying_amount: D.new("0.01")
    })
    |> Repo.insert!()

    cms_account = cms_account_fixture()
    {:ok, lms_account} = Enrollment.enroll(cms_account.account_id, scheme.id)

    PointsEngine.process_transaction(cms_account.account_id, %{
      amount: "70.00", transaction_date: Date.utc_today(),
      merchant_id: nil, clearing_record_id: Ecto.UUID.generate()
    })

    Repo.get!(Account, lms_account.id)
  end

  describe "perform/1" do
    test "releases a WAREHOUSE entry once warehouse_days has elapsed" do
      account = warehousing_account_fixture(30)
      assert D.equal?(account.open_to_redeem, D.new("0"))

      entry = Repo.get_by!(PointsLedger, lms_account_id: account.id)
      assert entry.warehouse_state == "WAREHOUSE"

      # Backdate posting so 30 days have already elapsed.
      entry |> PointsLedger.changeset(%{posting_date: Date.add(Date.utc_today(), -31)}) |> Repo.update!()

      assert :ok = WarehouseReleaseJob.perform(%Oban.Job{})

      released_account = Repo.get!(Account, account.id)
      assert D.equal?(released_account.open_to_redeem, D.new("70"))
      # points_balance/lifetime_earned were already correct at earn time —
      # release must not double-count them.
      assert D.equal?(released_account.points_balance, D.new("70"))

      released_entry = Repo.get!(PointsLedger, entry.id)
      assert released_entry.warehouse_state == "ACTIVE"
    end

    test "does not release before warehouse_days has elapsed" do
      account = warehousing_account_fixture(30)
      # Posted today — 30 days have not elapsed.

      assert :ok = WarehouseReleaseJob.perform(%Oban.Job{})

      unchanged = Repo.get!(Account, account.id)
      assert D.equal?(unchanged.open_to_redeem, D.new("0"))

      entry = Repo.get_by!(PointsLedger, lms_account_id: account.id)
      assert entry.warehouse_state == "WAREHOUSE"
    end

    test "immediate-earn accounts (warehouse_days: 0) are untouched — nothing to release" do
      account = warehousing_account_fixture(0)
      assert D.equal?(account.open_to_redeem, D.new("70"))

      assert :ok = WarehouseReleaseJob.perform(%Oban.Job{})

      unchanged = Repo.get!(Account, account.id)
      assert D.equal?(unchanged.open_to_redeem, D.new("70"))
    end
  end
end
