defmodule VmuCore.DPS.DisputeLifecycleTest do
  use ExUnit.Case, async: false

  alias VmuCore.{Repo, DPS.Dispute}
  alias Decimal, as: D

  @account_id "dps-test-acct-001"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  describe "Dispute.file/1" do
    test "creates dispute in FILED state with deadlines" do
      attrs = %{
        account_id:      @account_id,
        transaction_date: Date.add(Date.utc_today(), -10),
        dispute_amount:   D.new("250.00"),
        reason_code:      "4853",
        network:          "MC"
      }

      {:ok, dispute} = Dispute.file(attrs)

      assert dispute.status == "FILED"
      assert dispute.chargeback_deadline != nil
      assert dispute.provisional_credit_posted == true
      assert Date.diff(dispute.chargeback_deadline, attrs.transaction_date) == 120
    end

    test "sets Visa chargeback deadline to 120 days" do
      attrs = %{
        account_id:       @account_id,
        transaction_date: Date.add(Date.utc_today(), -5),
        dispute_amount:   D.new("100.00"),
        reason_code:      "30",
        network:          "VI"
      }

      {:ok, dispute} = Dispute.file(attrs)
      assert Date.diff(dispute.chargeback_deadline, attrs.transaction_date) == 120
    end
  end

  describe "Dispute.transition/2" do
    test "transitions FILED -> RETRIEVAL_REQUESTED -> CHARGEBACK_FILED" do
      {:ok, dispute} = Dispute.file(%{
        account_id:       @account_id,
        transaction_date: Date.add(Date.utc_today(), -20),
        dispute_amount:   D.new("500.00"),
        reason_code:      "4853"
      })

      {:ok, d2} = Dispute.transition(dispute.dispute_id, "RETRIEVAL_REQUESTED")
      assert d2.status == "RETRIEVAL_REQUESTED"

      {:ok, d3} = Dispute.transition(dispute.dispute_id, "CHARGEBACK_FILED")
      assert d3.status == "CHARGEBACK_FILED"
    end

    test "can close as CLOSED_WIN" do
      {:ok, dispute} = Dispute.file(%{
        account_id:       @account_id,
        transaction_date: Date.add(Date.utc_today(), -30),
        dispute_amount:   D.new("150.00"),
        reason_code:      "4853"
      })

      {:ok, closed} = Dispute.transition(dispute.dispute_id, "CLOSED_WIN")
      assert closed.status == "CLOSED_WIN"
      assert closed.closed_at != nil
    end
  end
end
