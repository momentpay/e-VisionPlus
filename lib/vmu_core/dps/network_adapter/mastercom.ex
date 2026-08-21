defmodule VmuCore.DPS.NetworkAdapter.Mastercom do
  @moduledoc """
  Real Mastercard Mastercom v6 API adapter (DPS-P5, FR-DPS-020).

  Re-ported 2026-07-29 from `Avenza/apps/vmu_dps` — see `MastercomClient`'s
  moduledoc for the fuller re-port note. This replaces the earlier stub
  (which returned `{:error, :not_implemented}` unconditionally) with the
  real message construction and signing; the stub's honesty was accurate
  at the time ("no Mastercom API credentials or client exist"), but that
  premise turned out to be only half true — the client existed, just in
  the sibling repo, and a real consumer key already sits in this
  project's own `.env`.

  Endpoint shapes below are grounded in Mastercard's own published OpenAPI
  spec (`static.developer.mastercard.com/content/mastercom/swagger/mastercom-v6.yaml`),
  not guessed:

    - `POST /claims` — create a claim (the docket a dispute's chargebacks/cases
      file under)
    - `POST /claims/{claim_id}/chargebacks` — file a chargeback
      (`chargebackType: "CHARGEBACK"` for first chargeback, `"SECOND_PRESENTMENT"`
      for the acquirer's rebuttal cycle — not used by this adapter, which only
      handles the issuer-side first-chargeback filing `Dispute.transition/2`
      dispatches on)
    - `GET /claims/{claim_id}` — full claim history (chargebacks/cases/fees) —
      used for `check_status/2` since `Dispute.network_ref` stores a single
      claim id, not the separate claim_id+chargeback_id pair the batch
      `PUT /chargebacks/status` endpoint expects

  `Dispute.network_ref` is used as the Mastercom **claim id**: `file_chargeback/2`
  creates one if the dispute doesn't have one yet, then files the chargeback
  under it and returns the claim id to be stored.

  ## Honest status

  This is a real, complete implementation of the message construction and
  signing — the only thing standing between this and a genuinely working
  integration is a private key (see `MastercomClient`'s moduledoc). Every
  call will correctly return `{:error, :missing_private_key}` until one is
  configured; nothing here fakes a successful response.
  """

  @behaviour VmuCore.DPS.NetworkAdapter

  alias VmuCore.DPS.NetworkAdapter.MastercomClient

  @impl true
  def file_chargeback(dispute, _config) do
    with {:ok, claim_id} <- ensure_claim(dispute),
         {:ok, _resp} <- file_chargeback_on_claim(claim_id, dispute) do
      {:ok, claim_id}
    end
  end

  @impl true
  def check_status(dispute, _config) do
    case dispute.network_ref do
      nil ->
        {:error, :no_network_ref}

      claim_id ->
        case MastercomClient.request(:get, "/claims/#{claim_id}") do
          {:ok, %{"claimStatus" => status}} -> {:ok, status}
          {:ok, resp} -> {:ok, inspect(resp)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp ensure_claim(%{network_ref: claim_id}) when is_binary(claim_id), do: {:ok, claim_id}

  defp ensure_claim(dispute) do
    body = %{
      "disputedAmount" => decimal_to_string(dispute.dispute_amount),
      "disputedCurrency" => dispute.currency || "USD",
      "claimType" => "DUAL_MESSAGE"
    }

    case MastercomClient.request(:post, "/claims", body) do
      {:ok, %{"claimId" => claim_id}} -> {:ok, claim_id}
      {:ok, resp} -> {:error, {:unexpected_response, resp}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp file_chargeback_on_claim(claim_id, dispute) do
    body = %{
      "currency" => dispute.currency || "USD",
      "reasonCode" => dispute.reason_code,
      "amount" => decimal_to_string(dispute.dispute_amount),
      "chargebackType" => "CHARGEBACK",
      "documentIndicator" => "N",
      "messageText" => "Issuer chargeback — dispute #{dispute.dispute_id}"
    }

    MastercomClient.request(:post, "/claims/#{claim_id}/chargebacks", body)
  end

  defp decimal_to_string(%Decimal{} = d), do: Decimal.to_string(d)
  defp decimal_to_string(other), do: to_string(other)
end
