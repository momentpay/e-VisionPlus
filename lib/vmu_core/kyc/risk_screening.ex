defmodule VmuCore.Kyc.RiskScreening do
  @moduledoc """
  Sanctions-screening gate on KYC approval (KYC-P4,
  `docs/kyc/KYC_Implementation_Tracker.md` §7). Reuses
  `VmuCore.CDM.SanctionsScreening.screen/1` — a real, already-proven direct
  (non-HTTP) call into `mw_risk`'s `MwRisk.SanctionsChecker` — rather than
  building a new integration. Confirmed by the user 2026-07-29: "the risk
  system mw-core/apps/mw_risk has LSEG implementation and it can be used."

  Deliberately **not** built as a `Kyc.ProviderAdapter` implementation —
  `ProviderAdapter.validate_field/2`'s shape (one form field's value) doesn't
  fit a customer-level sanctions check; forcing it through that behaviour
  would be a worse abstraction than calling `CDM.SanctionsScreening` here
  directly.

  Screens the **customer** record (`Shared.Customer`), not the request's
  `data` map — sanctions screening is about the person/entity, not whichever
  form-field keys a particular method happened to define. Inherits
  `SanctionsScreening.screen/1`'s fail-**closed** posture: `:error` (the
  screen couldn't complete) is never treated as clear.
  """

  alias VmuCore.Repo
  alias VmuCore.Shared.Customer
  alias VmuCore.CDM.SanctionsScreening
  alias VmuCore.Kyc.Request

  @type result :: :clear | {:hit, SanctionsScreening.hit()} | :error

  @doc "Screen the customer behind `request` for sanctions matches."
  @spec screen_request(Request.t()) :: result()
  def screen_request(%Request{customer_id: customer_id}) do
    case Repo.get(Customer, customer_id) do
      nil -> :error
      customer -> SanctionsScreening.screen(%{full_name: full_name(customer), company_name: customer.company_name})
    end
  end

  defp full_name(%Customer{first_name: first, last_name: last}) do
    [first, last]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
  end
end
