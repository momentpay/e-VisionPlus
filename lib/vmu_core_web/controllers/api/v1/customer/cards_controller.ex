defmodule VmuCoreWeb.Api.V1.Customer.CardsController do
  @moduledoc """
  Cardholder-facing card listing — NTS Phase F6 (2026-08-02), the first
  real consumer of `CTA.Cards.by_customer/1`. Under `:api_v1_cardholder`
  — lists only the authenticated cardholder's own cards.
  """

  use Phoenix.Controller, formats: [:json]

  alias VmuCore.CTA.Cards
  alias VmuCoreWeb.Plugs.ApiV1Auth
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @doc "GET /api/v1/customer/cards"
  def index(conn, _params) do
    conn = ApiV1Auth.require_scope(conn, "nts:customer")

    if conn.halted do
      conn
    else
      cards = Cards.by_customer(conn.assigns.current_customer_id)
      json(conn, ErrorEnvelope.ok(%{cards: Enum.map(cards, &card_json/1)}))
    end
  end

  defp card_json(c) do
    %{
      card_id: c.card_id, card_type: c.card_type, status: c.status,
      last_four: c.last_four, expiry: c.expiry, emboss_name: c.emboss_name
    }
  end
end
