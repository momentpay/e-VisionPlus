defmodule VmuCoreWeb.Api.V1.Customer.NtsController do
  @moduledoc """
  Cardholder-facing MDES Token Connect surface — NTS Phase F2 (2026-08-02)
  Case 1 (Push to Merchant), Phase F4 (2026-08-02) Case 5 (Pull from
  Wallet). Sits under `:api_v1_cardholder` (`ApiV1Auth` + `CardholderAuth`)
  — every action here acts on behalf of `conn.assigns.current_customer_id`,
  never a client-supplied customer id.
  """

  use Phoenix.Controller, formats: [:json]

  alias VmuCore.NTS.PushProvisioningSessions
  alias VmuCoreWeb.Plugs.ApiV1Auth
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @doc "GET /api/v1/customer/nts/eligible_token_requestors?card_id=...&type=MERCHANT"
  def eligible_token_requestors(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "nts:customer")

    if conn.halted do
      conn
    else
      with {:ok, card_id} <- require_param(params, "card_id"),
           true <- owns_card?(conn, card_id),
           {:ok, requestors} <- PushProvisioningSessions.list_eligible_token_requestors(card_id, params["type"]) do
        json(conn, ErrorEnvelope.ok(%{token_requestors: requestors}))
      else
        {:error, :missing_param} -> ErrorEnvelope.send(conn, 422, "missing_params", "card_id is required")
        false -> ErrorEnvelope.send(conn, 403, "forbidden", "This card does not belong to you")
        {:error, :card_not_found} -> ErrorEnvelope.send(conn, 404, "card_not_found", "No card with that id")
        {:error, :logo_not_found} -> ErrorEnvelope.send(conn, 422, "logo_not_configured", "This card's product isn't configured for tokenization")
        {:error, reason} -> ErrorEnvelope.send(conn, 502, "mdes_error", "MDES request failed: #{inspect(reason)}")
      end
    end
  end

  @doc "POST /api/v1/customer/nts/push_sessions"
  def create_push_session(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "nts:customer")

    if conn.halted do
      conn
    else
      with {:ok, attrs} <- build_push_attrs(params),
           true <- owns_card?(conn, attrs.card_id) do
        case PushProvisioningSessions.start_push(
               attrs.card_id, conn.assigns.current_customer_id, attrs.token_requestor_id, attrs.funding_account
             ) do
          {:ok, session, redirect_url} ->
            conn |> put_status(201) |> json(ErrorEnvelope.ok(%{
              session_id: session.session_id, status: session.status, redirect_url: redirect_url
            }))

          {:error, reason} ->
            ErrorEnvelope.send(conn, 502, "push_failed", "MDES push failed: #{inspect(reason)}")
        end
      else
        {:error, message} -> ErrorEnvelope.send(conn, 422, "missing_params", message)
        false -> ErrorEnvelope.send(conn, 403, "forbidden", "This card does not belong to you")
      end
    end
  end

  @doc """
  POST /api/v1/customer/nts/pull_sessions — Case 5, Pull from Wallet
  (Phase F4). Called after the cardholder has landed in Kosa via a
  wallet redirect (carrying `wallet_session_id`/`wallet_callback_url`
  as query params, per case-5's doc) and authenticated (CAM) and picked
  a card.
  """
  def create_pull_session(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "nts:customer")

    if conn.halted do
      conn
    else
      with {:ok, attrs} <- build_pull_attrs(params),
           true <- owns_card?(conn, attrs.card_id) do
        case PushProvisioningSessions.start_pull(
               attrs.card_id, conn.assigns.current_customer_id, attrs.token_requestor_id, attrs.funding_account,
               wallet_session_id: attrs.wallet_session_id, wallet_callback_url: attrs.wallet_callback_url
             ) do
          {:ok, session, redirect_url} ->
            conn |> put_status(201) |> json(ErrorEnvelope.ok(%{
              session_id: session.session_id, status: session.status, redirect_url: redirect_url
            }))

          {:error, reason} ->
            ErrorEnvelope.send(conn, 502, "push_failed", "MDES push failed: #{inspect(reason)}")
        end
      else
        {:error, message} -> ErrorEnvelope.send(conn, 422, "missing_params", message)
        false -> ErrorEnvelope.send(conn, 403, "forbidden", "This card does not belong to you")
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp owns_card?(conn, card_id), do: PushProvisioningSessions.card_belongs_to_customer?(card_id, conn.assigns.current_customer_id)

  defp require_param(params, key) do
    case params[key] do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> {:error, :missing_param}
    end
  end

  defp build_push_attrs(%{
         "card_id" => card_id, "token_requestor_id" => trid,
         "pan" => pan, "expiry_month" => month, "expiry_year" => year
       }) when is_binary(card_id) and is_binary(trid) and is_binary(pan) do
    {:ok, %{
      card_id: card_id, token_requestor_id: trid,
      funding_account: %{"cardAccountData" => %{"accountNumber" => pan, "expiryMonth" => month, "expiryYear" => year}}
    }}
  end

  defp build_push_attrs(_params) do
    {:error, "card_id, token_requestor_id, pan, expiry_month, and expiry_year are required"}
  end

  defp build_pull_attrs(%{
         "card_id" => card_id, "token_requestor_id" => trid,
         "wallet_session_id" => wallet_session_id, "wallet_callback_url" => wallet_callback_url,
         "pan" => pan, "expiry_month" => month, "expiry_year" => year
       }) when is_binary(card_id) and is_binary(trid) and is_binary(wallet_session_id) and
              is_binary(wallet_callback_url) and is_binary(pan) do
    {:ok, %{
      card_id: card_id, token_requestor_id: trid,
      wallet_session_id: wallet_session_id, wallet_callback_url: wallet_callback_url,
      funding_account: %{"cardAccountData" => %{"accountNumber" => pan, "expiryMonth" => month, "expiryYear" => year}}
    }}
  end

  defp build_pull_attrs(_params) do
    {:error, "card_id, token_requestor_id, wallet_session_id, wallet_callback_url, pan, expiry_month, and expiry_year are required"}
  end
end
