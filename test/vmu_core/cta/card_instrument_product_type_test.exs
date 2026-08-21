defmodule VmuCore.CTA.CardInstrumentProductTypeTest do
  @moduledoc """
  Koṣa domain-model alignment (2026-07-28) — `Card.instrument_product_type/1`
  derives the product a card belongs to from which of the three polymorphic
  refs is set, instead of every caller re-deriving it.
  """

  use ExUnit.Case, async: true

  alias VmuCore.CTA.Card

  test "returns :CREDIT when only account_id is set" do
    card = %Card{account_id: Ecto.UUID.generate()}
    assert Card.instrument_product_type(card) == :CREDIT
  end

  test "returns :DEBIT when only debit_account_id is set" do
    card = %Card{debit_account_id: Ecto.UUID.generate()}
    assert Card.instrument_product_type(card) == :DEBIT
  end

  test "returns :PREPAID when only prepaid_account_id is set" do
    card = %Card{prepaid_account_id: Ecto.UUID.generate()}
    assert Card.instrument_product_type(card) == :PREPAID
  end
end
