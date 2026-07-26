defmodule VmuCore.CMS.DebitFundingTest do
  @moduledoc """
  Way4 parity plan Phase 1 item 4 (Debit, D2) — `DebitFunding` changeset
  coverage, in particular that external channels require a reference
  (the only thing a future reconciliation file could match against)
  while internal/admin channels don't.
  """

  use ExUnit.Case, async: true

  alias VmuCore.CMS.DebitFunding
  alias Decimal, as: D

  defp valid_attrs(overrides \\ %{}) do
    Map.merge(%{
      debit_account_id: Ecto.UUID.generate(), amount: D.new("100.00"),
      channel: "INTERNAL_TRANSFER", posted_by: "operator1"
    }, overrides)
  end

  test "valid internal-transfer attrs produce a valid changeset" do
    changeset = DebitFunding.changeset(%DebitFunding{}, valid_attrs())
    assert changeset.valid?
  end

  test "rejects an unknown channel" do
    changeset = DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{channel: "BOGUS"}))
    refute changeset.valid?
  end

  test "rejects a zero or negative amount" do
    assert %{valid?: false} = DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{amount: D.new(0)}))
    assert %{valid?: false} = DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{amount: D.new("-5.00")}))
  end

  test "EXTERNAL_BANK_TRANSFER requires external_reference" do
    changeset = DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{channel: "EXTERNAL_BANK_TRANSFER"}))
    refute changeset.valid?
    assert %{external_reference: ["can't be blank"]} = errors_on(changeset)

    changeset =
      DebitFunding.changeset(%DebitFunding{},
        valid_attrs(%{channel: "EXTERNAL_BANK_TRANSFER", external_reference: "BANKREF-1"}))
    assert changeset.valid?
  end

  test "CASH_DEPOSIT requires external_reference" do
    changeset = DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{channel: "CASH_DEPOSIT"}))
    refute changeset.valid?
  end

  test "INTERNAL_TRANSFER and ADMIN_MANUAL don't require external_reference" do
    assert DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{channel: "INTERNAL_TRANSFER"})).valid?
    assert DebitFunding.changeset(%DebitFunding{}, valid_attrs(%{channel: "ADMIN_MANUAL"})).valid?
  end

  defp errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
