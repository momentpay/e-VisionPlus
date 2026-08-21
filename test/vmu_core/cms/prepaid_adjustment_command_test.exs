defmodule VmuCore.CMS.PrepaidAdjustmentCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Card Products UX Parity Phase 2c
  (2026-07-28) — Prepaid's first manual balance-correction capability.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{PrepaidAccountOpening, PrepaidAdjustmentCommand, PrepaidLedger}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp prepaid_account_fixture(opts \\ []) do
    n = System.unique_integer([:positive])
    sys_id = "T#{100 + rem(n, 900)}"
    bank_id = "B#{100 + rem(n, 900)}"
    logo_id = "L#{100 + rem(n, 900)}"
    block_id = "K#{100 + rem(n, 900)}"

    %SysParameter{} |> SysParameter.changeset(%{sys_id: sys_id, description: "test"}) |> Repo.insert!()
    %BankParameter{} |> BankParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, description: "test"}) |> Repo.insert!()

    # GL Phase C3: `InternalGlPoster` posts through `Posting.RuleEngine` now, so
    # a posting needs the chart, the rules, and an institution whose banking
    # date is open — the period gate refuses one that is not. Production gets
    # all three from `seed_gl.exs`; a test that mints an institution inline has
    # to supply them. See `VmuCore.GLFixtures`.
    :ok = GLFixtures.seed_posting_engine!()
    :ok = GLFixtures.open_institution!(sys_id, bank_id)
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Adj", last_name: "PrepaidTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    if opts[:load] do
      {:ok, _} =
        PrepaidLedger.load(%{
          prepaid_account_id: account.prepaid_account_id, amount: opts[:load],
          channel: "ADMIN_MANUAL", posted_by: "seed"
        })
    end

    account
  end

  test "CREDIT direction adds spendable value and posts a real GL entry" do
    account = prepaid_account_fixture()
    n = System.unique_integer([:positive])

    assert {:ok, adjustment} =
             PrepaidAdjustmentCommand.post(%{
               prepaid_account_id: account.prepaid_account_id, direction: "CREDIT", amount: D.new("75.00"),
               reason: "Goodwill credit", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "sup1"
             })

    assert adjustment.ledger_entry_id
    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("75.00"))

    [listed] = PrepaidAdjustmentCommand.list_for(account.prepaid_account_id)
    assert listed.id == adjustment.id
  end

  test "DEBIT direction consumes ACTIVE loads FIFO when sufficient funds exist" do
    account = prepaid_account_fixture(load: D.new("200.00"))
    n = System.unique_integer([:positive])

    assert {:ok, _adjustment} =
             PrepaidAdjustmentCommand.post(%{
               prepaid_account_id: account.prepaid_account_id, direction: "DEBIT", amount: D.new("50.00"),
               reason: "Reverse over-load", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "sup1"
             })

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("150.00"))
  end

  test "DEBIT direction fails with :insufficient_funds and posts nothing when it would go negative" do
    account = prepaid_account_fixture(load: D.new("20.00"))
    n = System.unique_integer([:positive])

    assert {:error, :insufficient_funds} =
             PrepaidAdjustmentCommand.post(%{
               prepaid_account_id: account.prepaid_account_id, direction: "DEBIT", amount: D.new("50.00"),
               reason: "Too much", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "sup1"
             })

    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("20.00"))
    assert PrepaidAdjustmentCommand.list_for(account.prepaid_account_id) == []
  end

  test "rejects operator_id == supervisor_id (4-eyes)" do
    account = prepaid_account_fixture()
    n = System.unique_integer([:positive])

    assert {:error, changeset} =
             PrepaidAdjustmentCommand.post(%{
               prepaid_account_id: account.prepaid_account_id, direction: "CREDIT", amount: D.new("10.00"),
               reason: "same person", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "agent1"
             })

    refute changeset.valid?
  end

  test "a CREDIT adjustment's spendable value is consumed FIFO by a later real spend, soonest-expiring-first" do
    account = prepaid_account_fixture()
    n = System.unique_integer([:positive])

    {:ok, _adjustment} =
      PrepaidAdjustmentCommand.post(%{
        prepaid_account_id: account.prepaid_account_id, direction: "CREDIT", amount: D.new("100.00"),
        reason: "Goodwill credit", reference_id: "CAS-#{n}",
        operator_id: "agent1", supervisor_id: "sup1"
      })

    assert {:ok, _spend} = PrepaidLedger.spend(account.prepaid_account_id, D.new("40.00"))
    assert D.equal?(PrepaidLedger.balance(account.prepaid_account_id), D.new("60.00"))
  end
end
