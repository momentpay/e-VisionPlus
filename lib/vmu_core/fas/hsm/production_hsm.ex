defmodule VmuCore.FAS.HSM.ProductionHSM do
  @moduledoc """
  Production HSM adapter — REST integration to Veriscent's cloud-hosted
  Thales payShield 10K (FAS-P7 7C). **Vendor/approach decided 2026-07-24**;
  still a stub (all callbacks `{:error, :not_implemented}`) — see `Way4_
  Parity_Implementation_Plan.md` Phase 0 item 7, not started yet.

  For the alternative connectivity option (direct TCP host-command socket,
  no REST intermediary), see `VmuCore.FAS.HSM.SocketHSM` — kept as a
  parallel stub, config-swappable via the same `:hsm_adapter` key, so
  neither integration path is picked irreversibly before real usage informs
  which one fits (Veriscent's REST wrapper adds a hop but is simpler to
  operate; a direct socket to an on-prem/co-located payShield removes that
  hop but needs the raw host-command framing this module's REST calls
  currently skip).

  ## Decided integration: Veriscent 10XPay REST API

  Reference material (Postman collection, real payShield 10K Host Commands
  V2.2b / Host Programmers V2.2b manuals, and real mTLS client credentials)
  lives in `D:\\momentPay\\Products\\E-VisionPlus\\Veriscent-HSM-cloud\\`
  — **do not commit or copy that folder's `slot_1/` contents into this
  repo**; `password.txt` and `Mercury RKL_keystore.pfx` are real
  credentials for connecting to Veriscent's HSM.

  - **Transport**: `POST https://{10XPAY_service_URL}/api/v1/rest/`, one
    endpoint for every host command, body shaped
    `{"messageHeader": "...", "commandCode": "<2-char code>", ...fields}`.
    Confirmed live against the reference Postman collection (`B2` echo,
    `NO` HSM status) — no bearer-token/API-key header on any sampled
    request; auth is mutual TLS (client cert), matching the `slot_1/`
    keystore + CA chain + passphrase already in the reference folder.
  - **This is the real Thales payShield 10K host command set**, just
    JSON/REST-wrapped instead of raw binary socket framing — every
    `VmuCore.FAS.HSM` callback maps to a real, named command:

    | Callback | Host command(s) | Confirmed in reference material |
    |---|---|---|
    | `verify_cvv/4` | `CY` — Verify a Card Verification Code or Value | ✅ exact match in the Postman collection |
    | `verify_arqc/5` + `generate_arpc/3` | `SA` / the ARQC-verification-and-ARPC-generation endpoints (EMV or cloud-based SKD, and static/Mastercard-proprietary SKD variants) | ✅ both variants present in the collection |
    | `verify_pin/3` | one of the `BC`/`BE`/`DA`/`DC`/`GU`/`GQ` PIN-verification family, depending on which PIN block format + verification method (IBM offset vs. ABA PVV vs. encrypted-PIN) this deployment's LMK/ZPK setup uses | ⚠️ family confirmed, exact command needs a real decision against `SoftHSM.verify_pin/3`'s existing ISO-0 PIN block format before implementation |
    | `change_pin/3` | PIN-translate (`JC`/`JE`/`JG` family) + a verify command, composed | ⚠️ same — exact composition is an implementation-time decision, not a single command |
    | `build_issuer_scripts/2` | the EMV issuer-script family (`IK`/`IM` — EMV Sign/Recover Data) | ⚠️ plausible mapping from the command list; not yet cross-checked against a real EMV script-generation example request |

  Rows marked ✅ are confirmed directly against a real sample request in the
  Postman collection; rows marked ⚠️ are the right command *family* per the
  standard payShield 10K host command set but need the exact command +
  field mapping picked from the real Host Commands manual (also in the
  reference folder) before implementation, not guessed.

  ## Config skeleton (REST path)

      # config/prod.exs
      config :vmu_core, :hsm_adapter, VmuCore.FAS.HSM.ProductionHSM
      config :vmu_core, :production_hsm,
        service_url: "10xpay.veriscent.example",   # real host TBD
        client_cert: "/path/to/deployed/keystore.pfx",  # never the repo copy
        client_cert_password_env: "VERISCENT_HSM_PFX_PASSWORD",
        ca_chain:    "/path/to/deployed/internal_ca_chain.crt",
        timeout_ms:  5_000,
        lmk_id:      1      # LMK variant for this VisionPlus instance

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
  def change_pin(_pan_token, _old_pin, _new_pin) do
    Logger.warning("[ProductionHSM] change_pin not implemented — stub")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def build_issuer_scripts(_pan_token, _commands) do
    Logger.warning("[ProductionHSM] build_issuer_scripts not implemented — stub")
    {:error, :not_implemented}
  end
end
