defmodule VmuCore.DPS.NetworkAdapter do
  @moduledoc """
  Behaviour contract for scheme dispute-network integration (DPS-P3, FR-DPS-020).

  Unlike `VmuCore.FAS.HSM` (one global adapter) or `VmuCore.DPS.EvidenceStore` (one
  adapter per bank), `dps.network_connectivity_mode` is a **map keyed per network**
  (`"VISA"`/`"MASTERCARD"` → `"manual"`/`"api"`) — `for_network/3` resolves the right
  adapter per dispute, not once globally.

  `VmuCore.DPS.Dispute.network` uses short codes (`"VI"`/`"MC"`); the config map uses
  full names (`"VISA"`/`"MASTERCARD"`) — `for_network/3` normalizes between them.

  ## Adapters

  - `VmuCore.DPS.NetworkAdapter.Manual` — real, formalizes today's actual process:
    ops re-keys the chargeback into the network's portal by hand; `network_ref` gets
    filled in later by an operator (already a `Dispute` field).
  - `VmuCore.DPS.NetworkAdapter.Vrol` (Visa Resolve Online) / `.Mastercom`
    (Mastercard) — stubs. No VROL/Mastercom API credentials or client exist in this
    project — every callback returns `{:error, :not_implemented}` until a real
    integration is built.
  """

  @doc "File a chargeback with the network. Returns the network's case reference, or `nil` if none yet (manual filing)."
  @callback file_chargeback(dispute :: VmuCore.DPS.Dispute.t(), config :: map()) ::
              {:ok, network_ref :: String.t() | nil} | {:error, term()}

  @doc "Check the network-side status of a filed case."
  @callback check_status(dispute :: VmuCore.DPS.Dispute.t(), config :: map()) ::
              {:ok, String.t()} | {:error, term()}

  @network_names %{"VI" => "VISA", "MC" => "MASTERCARD", "VISA" => "VISA", "MASTERCARD" => "MASTERCARD"}

  @doc "Resolves the configured adapter module for `network`, given the dispute's bank scope."
  @spec for_network(String.t(), String.t(), String.t()) :: module()
  def for_network(network, sys_id, bank_id) do
    network_key = Map.get(@network_names, network, network)

    {:ok, modes} =
      VmuCore.Shared.ModuleConfigEngine.get("dps", "network_connectivity_mode", sys_id, bank_id)

    case Map.get(modes, network_key, "manual") do
      "manual" -> __MODULE__.Manual
      "api" -> api_adapter(network_key)
      _ -> __MODULE__.Manual
    end
  end

  defp api_adapter("VISA"), do: __MODULE__.Vrol
  defp api_adapter("MASTERCARD"), do: __MODULE__.Mastercom
  defp api_adapter(_other), do: __MODULE__.Manual
end
