defmodule VmuCore.FAS.HSM.ProductionHSM do
  @moduledoc """
  Production HSM adapter placeholder (FAS-P7 7C).

  This module is a connection skeleton only. Actual implementation requires
  selection of an HSM vendor (Thales payShield 9000/10K, Utimaco Se-Series,
  nCipher nShield) and vendor-supplied Elixir/Erlang client library or a
  custom TCP/PKCS#11 binding.

  ## Integration approaches

  1. **TCP host commands (recommended)**: Thales and Utimaco expose a TCP
     command set (Thales: Host Security Module commands; Utimaco: PKCS#11 over
     network socket). Connection pool via `NimblePool` or `Poolboy`.

  2. **PKCS#11**: Mount the vendor's cryptoki shared library, call via Erlang
     NIF or an Elixir port process. Less portable; preferred when HSM is
     co-located.

  3. **REST gateway**: Some HSMs expose REST APIs (Thales Data Protection On
     Demand). Suitable for cloud deployments.

  ## Config skeleton

      # config/prod.exs
      config :vmu_core, :production_hsm,
        host:       "10.0.1.50",
        port:       1500,
        pool_size:  4,
        timeout_ms: 5_000,
        lmk_id:     1      # LMK variant for this VisionPlus instance

  ## Status

  All callbacks return `{:error, :not_implemented}` until the vendor adapter
  is wired. The auth pipeline fails-open on `:not_implemented` to avoid
  blocking transactions when the HSM is unavailable during initial rollout —
  see `VmuCore.FAS.Authorization.hsm_fail_open?/0`.
  """

  @behaviour VmuCore.FAS.HSM
  require Logger

  @impl VmuCore.FAS.HSM
  def verify_cvv(_pan, _expiry, _service_code, _cvv) do
    Logger.warning("[ProductionHSM] verify_cvv not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def verify_arqc(_pan_token, _atc, _un, _txn_data, _arqc) do
    Logger.warning("[ProductionHSM] verify_arqc not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def generate_arpc(_arqc, _arc, _pan_token) do
    Logger.warning("[ProductionHSM] generate_arpc not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def verify_pin(_pin_block_hex, _pan, _pan_token) do
    Logger.warning("[ProductionHSM] verify_pin not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def build_issuer_scripts(_pan_token, _commands) do
    Logger.warning("[ProductionHSM] build_issuer_scripts not implemented — stub")
    {:error, :not_implemented}
  end
end
