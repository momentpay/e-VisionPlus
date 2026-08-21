defmodule VmuCore.Kyc.WalletStepUp do
  @moduledoc """
  Auto-triggers a step-up WALLET KYC request when
  `CMS.WalletVelocityLimits.check/2` declines a funding attempt — Digital
  Wallet Phase W5 follow-up (2026-07-29), closing W008 (the doc's
  "step-up KYC" requirement only ever had the general submit/review path;
  nothing ever triggered it automatically on a limit breach).

  Deliberately the one CMS -> Kyc call in this direction (`WalletFundingCommand`
  calls this, not the reverse) — money-movement code decides *that* a
  step-up is needed; this module owns *how* a KYC request gets created for
  it.
  """

  alias VmuCore.Kyc.{Methods, Request, Requests}

  @doc """
  Ensures a submitted/under_review WALLET step-up request exists for this
  customer. No-ops (returns `:already_pending`) if one is already open, so a
  customer who keeps retrying a blocked load doesn't spawn a duplicate
  request per attempt. Skips gracefully (`:no_method_configured`) if there
  is no active WALLET method configured, or more than one (ambiguous — an
  admin needs to resolve which one is the step-up method before this can
  pick automatically).
  """
  @spec trigger(binary()) ::
          {:ok, Request.t()} | :already_pending | :no_method_configured | {:error, term()}
  def trigger(customer_id) do
    case Methods.ordered_for_product("WALLET") do
      [method] ->
        if pending_request?(customer_id, method) do
          :already_pending
        else
          Requests.submit(method, %{"customer_id" => customer_id, "data" => %{}})
        end

      _other ->
        :no_method_configured
    end
  end

  defp pending_request?(customer_id, method) do
    Requests.list(%{"customer_id" => customer_id, "product_type" => "WALLET"})
    |> Enum.any?(&(&1.kyc_method_id == method.method_id and &1.status in ["submitted", "under_review"]))
  end
end
