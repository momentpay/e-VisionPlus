defmodule VmuCore.FAS.HSM.SocketHSM do
  @moduledoc """
  Production HSM adapter — direct TCP host-command socket, kept as a
  parallel option to `VmuCore.FAS.HSM.ProductionHSM`'s REST integration
  (FAS-P7 7C). Not started; stub only, per the same "keep it as a real
  option, don't build it yet" decision that scoped `ProductionHSM`'s own
  REST work — see `Way4_Parity_Implementation_Plan.md` Phase 0 item 7.

  ## Why this exists alongside the REST adapter

  Veriscent's 10XPay REST API (`ProductionHSM`) wraps the same real payShield
  10K host commands in JSON over HTTPS+mTLS — simpler to operate, but an
  extra hop and a third-party dependency on Veriscent's own REST gateway
  staying up. This module is the alternative: a direct TCP connection
  speaking the classic Thales host-command wire protocol (binary,
  length-prefixed frames — the same command codes as `ProductionHSM`'s
  table, e.g. `CY` for `verify_cvv/4`, just framed differently), for a
  scenario where the HSM is reachable directly (on-prem, co-located, or a
  private network path to the vendor) without Veriscent's REST layer in
  between. Both are config-swappable via the same `:hsm_adapter` key —
  neither is committed to until real deployment topology is known.

  ## Integration approach (not yet built)

  Thales's TCP host-command protocol: a persistent socket, each request a
  length-prefixed binary frame (command code + fields packed per the
  payShield 10K Host Programmers manual — same reference material as
  `ProductionHSM`, in `D:\\momentPay\\Products\\E-VisionPlus\\
  Veriscent-HSM-cloud\\` locally). A connection pool (`NimblePool` or
  `Poolboy`) would own a fixed number of persistent sockets rather than
  opening one per request, matching this codebase's existing `AsyncCorrelator`
  connection-pool pattern in `muNSwitch`/`DaProductApp`.

  ## Config skeleton

      # config/prod.exs
      config :vmu_core, :hsm_adapter, VmuCore.FAS.HSM.SocketHSM
      config :vmu_core, :socket_hsm,
        host:       "10.0.1.50",   # real host TBD if this path is chosen
        port:       1500,
        pool_size:  4,
        timeout_ms: 5_000,
        lmk_id:     1

  ## Status

  All callbacks return `{:error, :not_implemented}`, same fail-open posture
  as `ProductionHSM` — see `VmuCore.FAS.Authorization.hsm_fail_open?/0`.
  """

  @behaviour VmuCore.FAS.HSM
  require Logger

  @impl VmuCore.FAS.HSM
  def verify_cvv(_pan, _expiry, _service_code, _cvv) do
    Logger.warning("[SocketHSM] verify_cvv not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def verify_arqc(_pan_token, _atc, _un, _txn_data, _arqc) do
    Logger.warning("[SocketHSM] verify_arqc not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def generate_arpc(_arqc, _arc, _pan_token) do
    Logger.warning("[SocketHSM] generate_arpc not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def verify_pin(_pin_block_hex, _pan, _pan_token) do
    Logger.warning("[SocketHSM] verify_pin not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def change_pin(_pan_token, _old_pin, _new_pin) do
    Logger.warning("[SocketHSM] change_pin not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def build_issuer_scripts(_pan_token, _commands) do
    Logger.warning("[SocketHSM] build_issuer_scripts not implemented — stub")
    {:error, :not_implemented}
  end
end
