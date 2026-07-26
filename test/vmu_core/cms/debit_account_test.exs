defmodule VmuCore.CMS.DebitAccountTest do
  @moduledoc """
  Way4 parity plan Phase 1 item 4 (Debit, D1) — schema/changeset coverage
  for the new, deliberately separate `cms_debit_accounts` table.
  """

  use ExUnit.Case, async: true

  alias VmuCore.CMS.DebitAccount
  alias Decimal, as: D

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(%{
      customer_id: Ecto.UUID.generate(), sys_id: "T001", bank_id: "B001",
      logo_id: "L001", block_id: "K001", opened_at: ~D[2026-07-26]
    }, overrides)
  end

  test "valid attrs produce a valid changeset with defaults applied" do
    changeset = DebitAccount.changeset(%DebitAccount{}, valid_attrs())
    assert changeset.valid?
    assert Ecto.Changeset.get_field(changeset, :status) == "ACTIVE"
    assert Ecto.Changeset.get_field(changeset, :currency) == "AED"
    assert D.equal?(Ecto.Changeset.get_field(changeset, :available_balance), D.new(0))
  end

  test "requires customer_id/sys_id/bank_id/logo_id/block_id/opened_at" do
    changeset = DebitAccount.changeset(%DebitAccount{}, %{})
    refute changeset.valid?
    errors = errors_on(changeset)
    for field <- [:customer_id, :sys_id, :bank_id, :logo_id, :block_id, :opened_at] do
      assert Map.has_key?(errors, field)
    end
  end

  test "rejects an invalid status" do
    changeset = DebitAccount.changeset(%DebitAccount{}, valid_attrs(%{status: "BOGUS"}))
    refute changeset.valid?
  end

  test "rejects a negative available_balance" do
    changeset = DebitAccount.changeset(%DebitAccount{}, valid_attrs(%{available_balance: D.new("-1.00")}))
    refute changeset.valid?
  end

  test "active?/1" do
    assert DebitAccount.active?(%DebitAccount{status: "ACTIVE"})
    refute DebitAccount.active?(%DebitAccount{status: "SUSPENDED"})
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
