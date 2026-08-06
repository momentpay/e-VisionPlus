defmodule VmuCore.DPS.DisputeLifecycleTest do
  use ExUnit.Case, async: false

  alias VmuCore.{Repo, DPS.Dispute}
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.Account
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  # `dps_disputes.account_id` has a real FK to `cms_accounts` — the fake
  # string `"dps-test-acct-001"` this file used previously never actually
  # inserted (found live, 2026-07-23, while building DPS-P5's own tests:
  # `Ecto.ChangeError`, "does not match type :binary_id" — this whole file
  # was failing before today's DPS-P5 work touched anything). Self-contained
  # fixture, same pattern as `DpsComponentTest` — this test DB carries no
  # seeded SYS/BANK/LOGO/BLOCK rows of its own.
  defp account_id_fixture do
    n = System.unique_integer([:positive])
    sys_id = "T#{(100 + rem(n, 900))}"
    bank_id = "B#{(100 + rem(n, 900))}"
    logo_id = "L#{(100 + rem(n, 900))}"
    block_id = "K#{(100 + rem(n, 900))}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()

    %BankParameter{}
    |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"})
    |> Repo.insert!()

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. Production gets
    # all three from `seed_gl.exs`; a test that mints an institution inline has
    # to supply them. See `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(sys_id, bank_id)

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
        sys_id: sys_id, bank_id: bank_id, first_name: "Test", last_name: "Holder",
        id_type: "PASSPORT", id_number: "LIFECYCLE-TEST-#{n}"
      })
      |> Repo.insert!()

    account =
      %Account{}
      |> Account.changeset(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id,
        block_id: block_id, pan_token: "lifecycle-test-pan-#{n}", last_four: "4242",
        expiry_date: "1230", credit_limit: D.new("10000.00")
      })
      |> Repo.insert!()

    account.account_id
  end

  describe "Dispute.file/1" do
    test "creates dispute in FILED state with deadlines" do
      attrs = %{
        account_id:      account_id_fixture(),
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
        account_id:       account_id_fixture(),
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
        account_id:       account_id_fixture(),
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
        account_id:       account_id_fixture(),
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
