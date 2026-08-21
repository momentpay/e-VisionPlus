defmodule VmuCore.CTA.CardAccountRefTest do
  @moduledoc """
  Way4 parity plan Phase 1 item 4 (Debit, D1) — `CTA.Card`'s new
  "exactly one of account_id/debit_account_id" invariant. `cta_cards.
  account_id` was relaxed from NOT NULL so a debit card can point at
  `debit_account_id` instead, since `CMS.Account` requires a
  credit_limit a debit account doesn't have.
  """

  use ExUnit.Case, async: true

  alias VmuCore.CTA.Card

  defp base_attrs(overrides) do
    Map.merge(%{pan_token: String.duplicate("a", 64), card_type: "PRIMARY",
                status: "INACTIVE", generation: 1}, overrides)
  end

  test "valid with only account_id set" do
    changeset = Card.changeset(%Card{}, base_attrs(%{account_id: Ecto.UUID.generate()}))
    assert changeset.valid?
  end

  test "valid with only debit_account_id set" do
    changeset = Card.changeset(%Card{}, base_attrs(%{debit_account_id: Ecto.UUID.generate()}))
    assert changeset.valid?
  end

  test "invalid with neither set" do
    changeset = Card.changeset(%Card{}, base_attrs(%{}))
    refute changeset.valid?
  end

  test "invalid with both set" do
    changeset =
      Card.changeset(%Card{}, base_attrs(%{
        account_id: Ecto.UUID.generate(), debit_account_id: Ecto.UUID.generate()
      }))
    refute changeset.valid?
  end
end
