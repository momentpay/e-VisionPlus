defmodule VmuCore.DPS.NetworkAdapter.Vrol do
  @moduledoc """
  Visa Resolve Online (VROL) API adapter placeholder (DPS-P3).

  Stub only — no VROL API credentials or client exist in this project. Every
  callback returns `{:error, :not_implemented}` until a real integration is built.

  ## What a real implementation needs

  - VROL API credentials (issuer ID, API key/cert) — resolved via
    `dps.network_connectivity_mode`'s companion config or a dedicated secrets
    reference, never a raw secret in `evidence_storage_config`-style plain config.
  - `file_chargeback/2`: submit the chargeback case (reason code, amount, RRN,
    transaction date) via VROL's case-filing endpoint; return `{:ok, vrol_case_id}`.
  - `check_status/2`: poll VROL's case-status endpoint for representment/pre-arb/
    arbitration updates.
  """

  @behaviour VmuCore.DPS.NetworkAdapter

  require Logger

  @impl true
  def file_chargeback(_dispute, _config) do
    Logger.warning("[DPS.NetworkAdapter.Vrol] not implemented — no VROL API client configured")
    {:error, :not_implemented}
  end

  @impl true
  def check_status(_dispute, _config) do
    Logger.warning("[DPS.NetworkAdapter.Vrol] not implemented — no VROL API client configured")
    {:error, :not_implemented}
  end
end
