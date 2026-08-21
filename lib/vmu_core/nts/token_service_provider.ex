defmodule VmuCore.NTS.TokenServiceProvider do
  @moduledoc """
  Behaviour for a scheme Token Service Provider — Network Tokenization
  Service Phase A (2026-07-29). Mirrors `VmuCore.CMS.RailProvider`'s
  pluggable-provider shape (same reasoning: `NTS.TokenLifecycle` calls
  whichever module `config :vmu_core, :tsp_provider` points to, so
  swapping in the real Mastercard MDES client later is a config change,
  not a rewrite of the domain model or `CardLifecycle` hooks around it).

  `VmuCore.NTS.TokenServiceProviders.Stub` was the only implementation
  until real MDES credentials/spec landed (2026-07-31, NTS Phase B) —
  `VmuCore.NTS.TokenServiceProviders.MastercardMdes` is now real.

  `provision_token/3`'s `status` return value is provider-declared, not
  assumed by `TokenLifecycle` — a synchronous provider can return
  `"ACTIVE"` with a real `dpan` immediately; MDES's real Push Provisioning
  flow only ever returns `"PUSHED"` (a receipt, `dpan: nil`) since the
  actual DPAN doesn't exist until the Token Requestor's own app finishes
  tokenization, which the issuer isn't always told about.
  """

  alias VmuCore.NTS.Token

  @doc "Ask the TSP to provision a new device token for a card."
  @callback provision_token(card :: struct(), device_info :: map(), wallet :: String.t()) ::
              {:ok, %{token_reference_id: String.t(), dpan: String.t() | nil, status: String.t()}} | {:error, term()}

  @callback suspend_token(Token.t()) :: {:ok, term()} | {:error, term()}
  @callback resume_token(Token.t()) :: {:ok, term()} | {:error, term()}
  @callback delete_token(Token.t()) :: {:ok, term()} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:vmu_core, :tsp_provider, VmuCore.NTS.TokenServiceProviders.Stub)
end
