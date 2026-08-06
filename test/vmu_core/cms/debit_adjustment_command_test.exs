defmodule VmuCore.CMS.DebitAdjustmentCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Card Products UX Parity Phase 1c
  (2026-07-28) — Debit's first manual balance-correction capability.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{DebitAccount, DebitAccountOpening, DebitAdjustmentCommand, DebitFundingCommand}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp debit_account_fixture(opts \\ []) do
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
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Adj", last_name: "DebitTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    if opts[:fund] do
      {:ok, _} =
        DebitFundingCommand.fund(%{
          debit_account_id: account.debit_account_id, amount: opts[:fund],
          channel: "ADMIN_MANUAL", posted_by: "seed"
        })
    end

    Repo.get!(DebitAccount, account.debit_account_id)
  end

  test "CREDIT direction increases available_balance and posts a real GL entry" do
    account = debit_account_fixture()
    n = System.unique_integer([:positive])

    assert {:ok, adjustment} =
             DebitAdjustmentCommand.post(%{
               debit_account_id: account.debit_account_id, direction: "CREDIT", amount: D.new("75.00"),
               reason: "Goodwill credit", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "sup1"
             })

    assert adjustment.ledger_entry_id

    updated = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(updated.available_balance, D.new("75.00"))

    [listed] = DebitAdjustmentCommand.list_for(account.debit_account_id)
    assert listed.id == adjustment.id
  end

  test "DEBIT direction decreases available_balance when sufficient funds exist" do
    account = debit_account_fixture(fund: D.new("200.00"))
    n = System.unique_integer([:positive])

    assert {:ok, _adjustment} =
             DebitAdjustmentCommand.post(%{
               debit_account_id: account.debit_account_id, direction: "DEBIT", amount: D.new("50.00"),
               reason: "Reverse over-funding", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "sup1"
             })

    updated = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(updated.available_balance, D.new("150.00"))
  end

  test "DEBIT direction fails with :insufficient_funds and posts nothing when it would go negative" do
    account = debit_account_fixture(fund: D.new("20.00"))
    n = System.unique_integer([:positive])

    assert {:error, :insufficient_funds} =
             DebitAdjustmentCommand.post(%{
               debit_account_id: account.debit_account_id, direction: "DEBIT", amount: D.new("50.00"),
               reason: "Too much", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "sup1"
             })

    updated = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(updated.available_balance, D.new("20.00"))
    assert DebitAdjustmentCommand.list_for(account.debit_account_id) == []
  end

  test "rejects operator_id == supervisor_id (4-eyes)" do
    account = debit_account_fixture()
    n = System.unique_integer([:positive])

    assert {:error, changeset} =
             DebitAdjustmentCommand.post(%{
               debit_account_id: account.debit_account_id, direction: "CREDIT", amount: D.new("10.00"),
               reason: "same person", reference_id: "CAS-#{n}",
               operator_id: "agent1", supervisor_id: "agent1"
             })

    refute changeset.valid?
  end
end
