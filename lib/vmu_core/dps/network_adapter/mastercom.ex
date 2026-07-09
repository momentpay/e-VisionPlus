defmodule VmuCore.DPS.NetworkAdapter.Mastercom do
  @moduledoc """
  Mastercard Mastercom API adapter placeholder (DPS-P3).

  Stub only — no Mastercom API credentials or client exist in this project. Every
  callback returns `{:error, :not_implemented}` until a real integration is built.

  ## What a real implementation needs

  - Mastercom API credentials (ICA number, API key/cert) — resolved via a secrets
    reference, never a raw secret in plain config.
  - `file_chargeback/2`: submit the chargeback case via Mastercom's case-filing
    endpoint; return `{:ok, mastercom_case_id}`.
  - `check_status/2`: poll Mastercom's case-status endpoint for representment/
    pre-arb/arbitration updates.
  """

  @behaviour VmuCore.DPS.NetworkAdapter

  require Logger

  @impl true
  def file_chargeback(_dispute, _config) do
    Logger.warning("[DPS.NetworkAdapter.Mastercom] not implemented — no Mastercom API client configured")
    {:error, :not_implemented}
  end

  @impl true
  def check_status(_dispute, _config) do
    Logger.warning("[DPS.NetworkAdapter.Mastercom] not implemented — no Mastercom API client configured")
    {:error, :not_implemented}
  end
end
