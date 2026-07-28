defmodule VmuCore.CMS.DebitNonMonetaryEventTest do
  @moduledoc """
  Real Postgres via Sandbox, no mocking. Card Products UX Parity Phase
  1e (2026-07-28) — Debit's first non-monetary maintenance event audit
  trail (address/phone/email/emboss-name/limit changes).
  """

  use ExUnit.Case, async: false

  alias VmuCore.Repo
  alias VmuCore.CMS.{DebitAccountOpening, DebitNonMonetaryEvent}
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
      |> Customer.changeset(%{sys_id: sys_id, bank_id: bank_id, first_name: "Nme", last_name: "DebitTest#{n}"})
      |> Repo.insert!()

    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: sys_id, bank_id: bank_id, logo_id: logo_id, block_id: block_id
      })

    account
  end

  test "records an address_change event with before/after values" do
    account = debit_account_fixture()
    operator_id = Ecto.UUID.generate()

    assert {:ok, event} =
             DebitNonMonetaryEvent.record(
               debit_account_id: account.debit_account_id,
               event_type: "address_change",
               old_value: %{"line1" => "Old St"},
               new_value: %{"line1" => "New Ave"},
               reason: "Customer request",
               operator_id: operator_id
             )

    assert event.event_type == "address_change"

    [listed] = DebitNonMonetaryEvent.history_for(account.debit_account_id)
    assert listed.id == event.id
  end

  test "rejects an unknown event_type" do
    account = debit_account_fixture()

    assert {:error, changeset} =
             DebitNonMonetaryEvent.record(
               debit_account_id: account.debit_account_id,
               event_type: "cycle_change",
               operator_id: Ecto.UUID.generate()
             )

    refute changeset.valid?
  end
end
