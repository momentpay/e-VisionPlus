defmodule VmuCore.DPS.NetworkAdapter.Manual do
  @moduledoc """
  Manual-portal network adapter — the real, working default (DPS-P3).

  Formalizes today's actual process: an ops operator re-keys the chargeback into
  the network's own portal (VROL / Mastercom Connect) by hand, and later fills in
  `Dispute.network_ref` themselves once the network issues a case reference. This
  adapter doesn't call anything external — it just confirms the manual path was
  taken and logs it for the audit trail.
  """

  @behaviour VmuCore.DPS.NetworkAdapter

  require Logger

  @impl true
  def file_chargeback(dispute, _config) do
    Logger.info("[DPS.NetworkAdapter.Manual] dispute #{dispute.dispute_id} (#{dispute.network}) " <>
                "requires manual portal filing — no network_ref assigned yet")
    {:ok, nil}
  end

  @impl true
  def check_status(_dispute, _config), do: {:error, :manual_check_required}
end
