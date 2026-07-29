defmodule VmuCore.NTS.TokenServiceProvider do
  @moduledoc """
  Behaviour for a scheme Token Service Provider — Network Tokenization
  Service Phase A (2026-07-29). Mirrors `VmuCore.CMS.RailProvider`'s
  pluggable-provider shape (same reasoning: `NTS.TokenLifecycle` calls
  whichever module `config :vmu_core, :tsp_provider` points to, so
  swapping in the real Mastercard MDES client later is a config change,
  not a rewrite of the domain model or `CardLifecycle` hooks around it).

  `VmuCore.NTS.TokenServiceProviders.Stub` is the only implementation
  until MDES credentials/spec land (see the NTS implementation plan) — it
  never pretends to succeed.
  """

  alias VmuCore.NTS.Token

  @doc "Ask the TSP to provision a new device token for a card."
  @callback provision_token(card :: struct(), device_info :: map(), wallet :: String.t()) ::
              {:ok, %{token_reference_id: String.t(), dpan: String.t(), status: String.t()}} | {:error, term()}

  @callback suspend_token(Token.t()) :: {:ok, term()} | {:error, term()}
  @callback resume_token(Token.t()) :: {:ok, term()} | {:error, term()}
  @callback delete_token(Token.t()) :: {:ok, term()} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:vmu_core, :tsp_provider, VmuCore.NTS.TokenServiceProviders.Stub)
end
