defmodule VmuCore.NTS.TokenServiceProviders.VisaVtsStub do
  @moduledoc """
  Visa Token Service interface placeholder — per the requirements doc's
  answer to open question 1, Visa VTS stays a stub/interface-only
  implementation for this phase (Mastercard MDES is the real one). Not
  wired up as the default `:tsp_provider` anywhere; exists so a future
  Visa-branded card's `NTS.Token.scheme` has a real (if inert) provider
  to resolve to instead of falling through to the generic `Stub`.
  """

  @behaviour VmuCore.NTS.TokenServiceProvider

  @impl true
  def provision_token(_card, _device_info, _wallet), do: {:error, :visa_vts_not_implemented}

  @impl true
  def suspend_token(_token), do: {:error, :visa_vts_not_implemented}

  @impl true
  def resume_token(_token), do: {:error, :visa_vts_not_implemented}

  @impl true
  def delete_token(_token), do: {:error, :visa_vts_not_implemented}
end
