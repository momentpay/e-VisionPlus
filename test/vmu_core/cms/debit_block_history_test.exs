defmodule VmuCore.CMS.DebitBlockHistoryTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Card Products UX Parity Phase
  1e (2026-07-28) — Debit's first account-level block capability,
  distinct from card-level block.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{DebitAccount, DebitAccountOpening, DebitBlockHistory}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

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
    %LogoParameter{} |> LogoParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, bin_prefix: "424242", description: "test"}) |> Repo.insert!()
    %BlockParameter{} |> BlockParameter.changeset(%{sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id}) |> Repo.insert!()

    customer =
      %Customer{}
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Block", last_name: "DebitTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    account
  end

  test "record_block/6 sets block fields on the account and appends history" do
    account = debit_account_fixture()
    operator_id = Ecto.UUID.generate()

    assert {:ok, entry} =
             DebitBlockHistory.record_block(
               account.debit_account_id, "F", "FRAUD_ALERT", "Suspicious activity", operator_id, "SUPERVISOR"
             )

    assert entry.action == "BLOCKED"

    updated = Repo.get!(DebitAccount, account.debit_account_id)
    assert updated.block_code == "F"
    assert updated.block_reason == "Suspicious activity"
    assert updated.blocked_at

    [history_entry] = DebitBlockHistory.history_for(account.debit_account_id)
    assert history_entry.id == entry.id
  end

  test "record_unblock/6 clears block fields and appends a second history row" do
    account = debit_account_fixture()
    operator_id = Ecto.UUID.generate()

    {:ok, _} = DebitBlockHistory.record_block(account.debit_account_id, "F", "FRAUD_ALERT", "hold", operator_id)

    assert {:ok, entry} =
             DebitBlockHistory.record_unblock(
               account.debit_account_id, "F", "INVESTIGATION_CLOSED", "Confirmed genuine", operator_id, "SUPERVISOR"
             )

    assert entry.action == "UNBLOCKED"

    updated = Repo.get!(DebitAccount, account.debit_account_id)
    assert is_nil(updated.block_code)
    assert is_nil(updated.block_reason)
    assert is_nil(updated.blocked_at)

    history = DebitBlockHistory.history_for(account.debit_account_id)
    assert length(history) == 2
  end

  test "rejects an unknown reason code" do
    # record_block/6 uses Repo.insert! inside its transaction (same
    # convention as the original CMS.BlockCodeHistory it mirrors) — an
    # invalid changeset raises rather than returning {:error, _}.
    account = debit_account_fixture()
    operator_id = Ecto.UUID.generate()

    assert_raise Ecto.InvalidChangesetError, fn ->
      DebitBlockHistory.record_block(account.debit_account_id, "F", "NOT_A_REAL_CODE", nil, operator_id)
    end
  end
end
