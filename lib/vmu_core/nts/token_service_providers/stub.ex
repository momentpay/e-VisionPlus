defmodule VmuCore.NTS.TokenServiceProviders.Stub do
  @moduledoc """
  The default `NTS.TokenServiceProvider` — no real MDES client/credentials
  exist yet (see the NTS implementation plan §2 for the concrete blocker
  list). Deliberately always declines rather than faking a provision, so a
  caller never mistakes "no TSP wired up" for "a token actually exists at
  the scheme."
  """

  @behaviour VmuCore.NTS.TokenServiceProvider

  @impl true
  def provision_token(_card, _device_info, _wallet), do: {:error, :tsp_not_configured}

  @impl true
  def suspend_token(_token), do: {:error, :tsp_not_configured}

  @impl true
  def resume_token(_token), do: {:error, :tsp_not_configured}

  @impl true
  def delete_token(_token), do: {:error, :tsp_not_configured}
end
