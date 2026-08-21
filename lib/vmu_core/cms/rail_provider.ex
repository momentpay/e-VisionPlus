defmodule VmuCore.CMS.RailProvider do
  @moduledoc """
  Behaviour for a wallet-out payment rail — Digital Wallet Phase W6
  (2026-07-29). Mirrors `VmuCore.Kyc.ProviderAdapter`'s pluggable-provider
  shape: `ExternalPaymentCommand` calls whichever module `config
  :vmu_core, :rail_provider` points to, so swapping in a real bank/
  aggregator integration later is a config change, not a rewrite of the
  risk gate or the state machine around it.

  `VmuCore.CMS.RailProviders.Stub` is the only implementation until a
  vendor is chosen — it never pretends to succeed; it returns
  `{:error, :rail_not_configured}` so the rest of the pipeline (risk
  screening, persistence, the external API contract) is provably wired
  end-to-end while the one piece that's genuinely blocked on an external
  decision stays honestly unbuilt.
  """

  alias VmuCore.CMS.ExternalPayment

  @doc "Hand the payment off to the rail. Called after the risk gate has approved it."
  @callback initiate(ExternalPayment.t()) ::
              {:ok, %{external_reference: String.t(), status: String.t()}} | {:error, term()}

  @doc "Poll the rail for a submitted payment's current status."
  @callback check_status(ExternalPayment.t()) ::
              {:ok, %{status: String.t()}} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:vmu_core, :rail_provider, VmuCore.CMS.RailProviders.Stub)
end
