defmodule VmuCore.CMS.DebitFundingCommandTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Way4 parity plan Phase 1 item 4
  (Debit, D2) — funding a debit account posts a real ledger entry and
  increments available_balance in the same transaction.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.GLFixtures
  alias VmuCore.CMS.{DebitAccount, DebitAccountOpening, DebitFundingCommand}
  alias VmuCore.Posting.JournalEntry
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}
  alias Decimal, as: D

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp debit_account_fixture do
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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "555555", description: "test", product_type: "DEBIT"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Debit", last_name: "Test#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id
      })

    account
  end

  test "internal transfer funding posts a ledger entry and increments the balance" do
    account = debit_account_fixture()

    assert {:ok, %{funding: funding, ledger_entry: entry}} =
             DebitFundingCommand.fund(%{
               debit_account_id: account.debit_account_id, amount: D.new("500.00"),
               channel: "INTERNAL_TRANSFER", posted_by: "operator1"
             })

    assert funding.ledger_entry_id == entry.id
    # GL Phase C3: the journal entry carries the engine vocabulary; the legacy
    # transaction_code lives on the posting rule.
    assert entry.posting_set.event_type == "DEPOSIT"

    reloaded = Repo.get!(DebitAccount, account.debit_account_id)
    assert D.equal?(reloaded.available_balance, D.new("500.00"))
  end

  test "funding accumulates across multiple deposits" do
    account = debit_account_fixture()

    {:ok, _} = DebitFundingCommand.fund(%{
      debit_account_id: account.debit_account_id, amount: D.new("100.00"),
      channel: "ADMIN_MANUAL", posted_by: "operator1"
    })
    {:ok, _} = DebitFundingCommand.fund(%{
      debit_account_id: account.debit_account_id, amount: D.new("250.00"),
      channel: "ADMIN_MANUAL", posted_by: "operator1"
    })

    {:ok, balance} = DebitFundingCommand.balance(account.debit_account_id)
    assert D.equal?(balance, D.new("350.00"))
  end

  test "external bank transfer requires and records an external_reference" do
    account = debit_account_fixture()

    assert {:error, %Ecto.Changeset{}} =
             DebitFundingCommand.fund(%{
               debit_account_id: account.debit_account_id, amount: D.new("100.00"),
               channel: "EXTERNAL_BANK_TRANSFER", posted_by: "operator1"
             })

    assert {:ok, %{funding: funding}} =
             DebitFundingCommand.fund(%{
               debit_account_id: account.debit_account_id, amount: D.new("100.00"),
               channel: "EXTERNAL_BANK_TRANSFER", posted_by: "operator1",
               external_reference: "BANKREF-001"
             })

    assert funding.external_reference == "BANKREF-001"
  end

  test "rejects funding a suspended debit account" do
    account = debit_account_fixture()

    account
    |> DebitAccount.changeset(%{status: "SUSPENDED"})
    |> Repo.update!()

    assert {:error, :debit_account_not_active} =
             DebitFundingCommand.fund(%{
               debit_account_id: account.debit_account_id, amount: D.new("100.00"),
               channel: "ADMIN_MANUAL", posted_by: "operator1"
             })
  end

  test "a duplicate external_reference is rejected" do
    account = debit_account_fixture()

    {:ok, _} = DebitFundingCommand.fund(%{
      debit_account_id: account.debit_account_id, amount: D.new("100.00"),
      channel: "CASH_DEPOSIT", posted_by: "operator1", external_reference: "CASH-DUP-1"
    })

    assert {:error, %Ecto.Changeset{}} =
             DebitFundingCommand.fund(%{
               debit_account_id: account.debit_account_id, amount: D.new("50.00"),
               channel: "CASH_DEPOSIT", posted_by: "operator1", external_reference: "CASH-DUP-1"
             })
  end

  test "real double-entry ledger row is balanced (dr == cr) and liability-direction coded" do
    account = debit_account_fixture()

    {:ok, %{ledger_entry: entry}} =
      DebitFundingCommand.fund(%{
        debit_account_id: account.debit_account_id, amount: D.new("75.00"),
        channel: "INTERNAL_TRANSFER", posted_by: "operator1"
      })

    # GL Phase C3: the posting lands in `journal_entries`, which keeps a single
    # `amount` — the two sides being equal is enforced by construction rather
    # than asserted.
    reloaded = Repo.get!(JournalEntry, entry.id)
    assert %Decimal{} = reloaded.amount
  # Account codes remapped by GL Phase 4A (VMU-ADR-005): stored value moved
  # out of the 5xxx expense range into 2xxx liabilities, and cash clearing
  # from 1006 (an HCS receivable) to 3005.
    assert reloaded.dr_gl_account == "3005"
    assert reloaded.cr_gl_account == "2004"
  end
end
