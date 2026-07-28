defmodule VmuCore.CMS.PrepaidBlockHistoryTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Card Products UX Parity Phase
  2d (2026-07-28) — Prepaid's first account-level block capability,
  distinct from card-level block.
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{PrepaidAccount, PrepaidAccountOpening, PrepaidBlockHistory}
  alias VmuCore.Shared.{BankParameter, BlockParameter, Customer, LogoParameter, SysParameter}

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Repo)
    Ecto.Adapters.SQL.Sandbox.mode(Repo, {:shared, self()})
    :ok
  end

  defp prepaid_account_fixture do
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
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Block", last_name: "PrepaidTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    account
  end

  test "record_block/6 sets block fields on the account and appends history" do
    account = prepaid_account_fixture()
    operator_id = Ecto.UUID.generate()

    assert {:ok, entry} =
             PrepaidBlockHistory.record_block(
               account.prepaid_account_id, "F", "FRAUD_ALERT", "Suspicious activity", operator_id, "SUPERVISOR"
             )

    assert entry.action == "BLOCKED"

    updated = Repo.get!(PrepaidAccount, account.prepaid_account_id)
    assert updated.block_code == "F"
    assert updated.block_reason == "Suspicious activity"
    assert updated.blocked_at

    [history_entry] = PrepaidBlockHistory.history_for(account.prepaid_account_id)
    assert history_entry.id == entry.id
  end

  test "record_unblock/6 clears block fields and appends a second history row" do
    account = prepaid_account_fixture()
    operator_id = Ecto.UUID.generate()

    {:ok, _} = PrepaidBlockHistory.record_block(account.prepaid_account_id, "F", "FRAUD_ALERT", "hold", operator_id)

    assert {:ok, entry} =
             PrepaidBlockHistory.record_unblock(
               account.prepaid_account_id, "F", "INVESTIGATION_CLOSED", "Confirmed genuine", operator_id, "SUPERVISOR"
             )

    assert entry.action == "UNBLOCKED"

    updated = Repo.get!(PrepaidAccount, account.prepaid_account_id)
    assert is_nil(updated.block_code)
    assert is_nil(updated.block_reason)
    assert is_nil(updated.blocked_at)

    history = PrepaidBlockHistory.history_for(account.prepaid_account_id)
    assert length(history) == 2
  end

  test "rejects an unknown reason code" do
    account = prepaid_account_fixture()
    operator_id = Ecto.UUID.generate()

    assert_raise Ecto.InvalidChangesetError, fn ->
      PrepaidBlockHistory.record_block(account.prepaid_account_id, "F", "NOT_A_REAL_CODE", nil, operator_id)
    end
  end
end
