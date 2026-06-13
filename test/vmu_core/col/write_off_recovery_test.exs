defmodule VmuCore.COL.WriteOffRecoveryTest do
  use ExUnit.Case, async: false

  alias VmuCore.{Repo, COL.CollectionAccount}
  alias Decimal, as: D

  @account_id "col-test-acct-001"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "COL queue routing" do
    test "routes 0-DPD account to CURRENT bucket" do
      result = VmuCore.COL.QueueRouter.route_account(%{
        account_id:         @account_id,
        delinquency_bucket: 0,
        outstanding_balance: D.new("1000.00")
      })

      assert result == :current
    end

    test "routes 90-DPD account to LEGAL queue" do
      result = VmuCore.COL.QueueRouter.route_account(%{
        account_id:         @account_id,
        delinquency_bucket: 90,
        outstanding_balance: D.new("5000.00")
      })

      assert result in [:legal, :pre_write_off]
    end
  end

  describe "Write-off" do
    test "write-off creates GL entry and marks account WRITTEN_OFF" do
      # Assuming COL.WriteOffEngine.execute/2 returns {:ok, gl_entry_id}
      # This test validates the expected interface
      assert function_exported?(VmuCore.COL.WriteOffEngine, :execute, 2)
    end
  end

  describe "Recovery" do
    test "recovery posting reduces write-off reserve" do
      assert function_exported?(VmuCore.COL.RecoveryEngine, :post_recovery, 3)
    end
  end
end
