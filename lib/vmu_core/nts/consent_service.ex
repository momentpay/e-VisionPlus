defmodule VmuCore.NTS.ConsentService do
  @moduledoc """
  Mastercard's Consent Service API — needed for Case 3, Push to Merchant
  with Authentication (NTS Phase F5, 2026-08-02). **Honestly not
  implemented**: `docs/nts/mdes-token-connect.yaml` only covers Token
  Connect; Consent Service (Activation Code Notification / Deliver
  Activation Code) is a separate Mastercard API with its own spec, which
  we don't have. Mirrors `TokenServiceProviders.MastercardMdes.
  suspend_token/1`'s established honesty pattern — return a clearly
  named error rather than guessing an endpoint shape.

  What IS real: case-3's doc says the Token Requestor learns whether
  Consent Service applies from `getEligibleTokenRequestors`'s own
  `supportsCardHolderAuthentication` flag — already passed through
  unmodified by `PushProvisioningSessions.list_eligible_token_requestors/2`,
  no separate call needed for that part. And `PushProvisioningSessions.
  complete/2` already routes a `REQUIRE_ADDITIONAL_AUTHENTICATION` TR
  callback result to the `AUTH_REQUIRED` session status (Phase F2) — the
  state machine for "this session is waiting on an activation code" is
  real. Only the actual Mastercard-side notify/deliver call is missing.
  """

  @doc """
  Would notify MDES's Consent Service that `session` requires the
  cardholder to confirm an activation code delivered out-of-band (SMS/
  email), per case-3's `activationMethod` flow. Always fails — see
  moduledoc.
  """
  @spec notify_activation_code_required(VmuCore.NTS.PushProvisioningSession.t(), String.t()) ::
          {:error, :consent_service_spec_not_available}
  def notify_activation_code_required(_session, _activation_code) do
    {:error, :consent_service_spec_not_available}
  end
end
