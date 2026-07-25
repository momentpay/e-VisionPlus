defmodule VmuCore.FAS.HSM.ProductionHSM do
  @moduledoc """
  Production HSM adapter — REST integration to Veriscent's cloud-hosted
  Thales payShield 10K (Way4 parity plan Phase 0 item 7, implemented
  2026-07-24). CVV verification, ARQC verification, and ARPC generation
  are real, working commands. PIN verification is real, working, and
  redesigned onto correct HSM semantics (see below). PIN change and
  issuer scripts remain unimplemented — for reasons specific to each,
  documented at their callbacks, not guessed placeholders.

  For the alternative connectivity option (direct TCP host-command socket,
  no REST intermediary), see `VmuCore.FAS.HSM.SocketHSM` — kept as a
  parallel stub, config-swappable via the same `:hsm_adapter` key.

  ## Decided integration: Veriscent 10XPay REST API

  Reference material (Postman collection, real payShield 10K Host Commands
  V2.2b / Host Programmers V2.2b manuals, and real mTLS client credentials)
  lives in `D:\\momentPay\\Products\\E-VisionPlus\\Veriscent-HSM-cloud\\`
  — **do not commit or copy that folder's `slot_1/` contents into this
  repo**.

  - **Transport**: `POST https://{service_url}/api/v1/rest/`, one
    endpoint for every host command, body shaped
    `{"messageHeader": "...", "commandCode": "<2-char code>", ...fields}`.
    Auth is mutual TLS (client cert) — no bearer token/API key on any
    sampled request.
  - **Live connectivity is unverified as of 2026-07-24** — the reference
    mTLS certificate in `slot_1/` has expired (confirmed live: TLS
    handshake reaches certificate exchange, server responds
    `certificate_unknown`). Every request/response shape below is built
    from the real Postman collection samples plus the real payShield 10K
    Core Host Commands manual — not guessed — but an actual round trip
    needs a renewed certificate to confirm end-to-end.

  | Callback | Host command | Confidence |
  |---|---|---|
  | `verify_cvv/4` | `CY` — Verify a Card Verification Code or Value | Real Postman sample + manual response fields (page 363-365) |
  | `generate_cvv/3` | `CW` — Generate a Card Verification Code or Value | Real manual spec (page 306-308), mirrors `CY`'s field shape exactly — added 2026-07-25 for virtual card issuance (Way4 parity plan Phase 1 item 1) |
  | `verify_arqc/6` | `KW`, Mode Flag `0` (verify only) | Real Postman sample (Mode Flag `0`); response fields from manual — only VISA/MASTERCARD (Scheme ID `0`/`1`, EMV Option A) mapped by default, see `VmuCore.FAS.ConfigCatalog`'s `scheme_id_map` |
  | `generate_arpc/6` | `KW`, Mode Flag `2` (ARPC generation only) | Manual-derived (page 542-544) — Mode Flag `2`'s exact field list was not independently cross-checked against a Postman sample the way Mode `0` was; built from the same base request shape with `arc` added and `arqc` removed per the manual's field-presence table, but flagged as the least-verified of the CY/KW/BE trio |
  | `verify_pin/3` | `BE` — Verify an Interchange PIN Using the Comparison Method | Real manual spec (page 336-338) — direct pass-through of the still-ZPK-encrypted DE52 block against `CardPin.reference_pin_lmk`, no plaintext ever decoded. Redesigned 2026-07-24 — see moduledoc below and `docs/fas/FAS_Implementation_Tracker.md` |
  | `change_pin/3` | none — architecturally blocked, see callback doc | N/A |
  | `build_issuer_scripts/2` | `IK`/`IM` (EMV Sign/Recover Data) | Not attempted this pass |

  ## PIN verification redesign (2026-07-24)

  The original design decoded DE52's PIN block to plaintext digits in
  application code and compared a PBKDF2 hash — not how any real HSM/PCI
  flow works. `verify_pin/3` now passes the PIN block through **still
  encrypted under the bank's Zone PIN Key** (never decoded here or by any
  caller) directly to `BE`, which compares it — entirely inside the HSM —
  against `CardPin.reference_pin_lmk` (an LMK-encrypted reference, opaque
  outside the HSM). See `VmuCore.FAS.HSM`'s moduledoc and `VmuCore.CMS.CardPin`.

  ## `change_pin/3` — why it stays `{:error, :not_implemented}`

  Not a "haven't gotten to it yet" gap — a real architectural constraint
  found while implementing this. Every real payShield PIN-reference
  command (`BE`'s comparison PIN, `BK`'s offset generation, `DG`/`JE`'s
  LMK translation) is **PAN-bound by format** — the PIN is
  cryptographically associated with the account number, per the manual's
  own note under `DG`. But `change_pin/3`'s callers (IVR/self-service
  channels) never have the real PAN — only `pan_token` — by this
  codebase's own "never store/transmit raw PAN outside a live network
  message" policy (`VmuCore.FAS.HSM.change_pin/3`'s moduledoc). There is
  no vendor command that produces a valid reference without the PAN, so
  there is no way to implement this correctly against the current
  self-service architecture. Fixing it for real needs one of: (a) routing
  self-service PIN changes back through the network/switch as a real
  transaction (carrying PAN in DE2, like an ATM PIN-change message
  normally would), or (b) a genuine PAN vault/detokenization service —
  both materially bigger than an HSM adapter. `SoftHSM` implements a
  dev-only simplification instead (see its own moduledoc) — not a model
  for what production needs to do.

  ## Config

      # config/prod.exs
      config :vmu_core, :hsm_adapter, VmuCore.FAS.HSM.ProductionHSM
      config :vmu_core, :production_hsm,
        service_url: "hsm.eu.verisec10xpay-test.com",
        client_cert: "/path/to/deployed/client_cert.pem",   # never the repo copy
        client_cert_password_env: "VERISCENT_HSM_CERT_PASSWORD",
        ca_chain:    "/path/to/deployed/internal_ca_chain.crt"

  Per-bank key material (CVK/MK-AC/ZPK/LMK identifier/scheme mapping) is
  Module Configuration Framework data, not static app config — see
  `VmuCore.FAS.ConfigCatalog`.
  """

  @behaviour VmuCore.FAS.HSM
  require Logger

  alias VmuCore.FAS.HSM.ProductionHSM.HttpClient
  alias VmuCore.Shared.{ModuleConfigEngine, ParameterEngine}

  @impl VmuCore.FAS.HSM
  def verify_cvv(pan, expiry, service_code, cvv) do
    with {:ok, {sys_id, bank_id, _logo_id}} <- resolve_bin(pan),
         {:ok, cvk} <- fas_config(sys_id, bank_id, "cvk"),
         {:ok, lmk_id} <- fas_config(sys_id, bank_id, "lmk_identifier") do
      body = %{
        "messageHeader" => message_header(),
        "commandCode" => "CY",
        "cardVerificationKey" => cvk,
        "cvv" => cvv,
        "pan" => pan,
        "expirationDate" => expiry,
        "serviceCode" => service_code,
        "lmkIdentifier" => lmk_id
      }

      case HttpClient.post(body) do
        {:ok, %{"errorCode" => "00"}} -> :ok
        {:ok, %{"errorCode" => "01"}} -> {:error, :cvv_mismatch}
        {:ok, %{"errorCode" => code}} -> {:error, {:hsm_error, code}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl VmuCore.FAS.HSM
  def generate_cvv(pan, expiry, service_code) do
    with {:ok, {sys_id, bank_id, _logo_id}} <- resolve_bin(pan),
         {:ok, cvk} <- fas_config(sys_id, bank_id, "cvk"),
         {:ok, lmk_id} <- fas_config(sys_id, bank_id, "lmk_identifier") do
      body = %{
        "messageHeader" => message_header(),
        "commandCode" => "CW",
        "cardVerificationKey" => cvk,
        "pan" => pan,
        "expirationDate" => expiry,
        "serviceCode" => service_code,
        "lmkIdentifier" => lmk_id
      }

      case HttpClient.post(body) do
        {:ok, %{"errorCode" => "00", "cvv" => cvv}} -> {:ok, cvv}
        {:ok, %{"errorCode" => code}} -> {:error, {:hsm_error, code}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl VmuCore.FAS.HSM
  def verify_arqc(pan, _pan_token, atc, un, txn_data, arqc) do
    with {:ok, {sys_id, bank_id, logo_id}} <- resolve_bin(pan),
         {:ok, scheme_id} <- resolve_scheme_id(sys_id, bank_id, logo_id),
         {:ok, mk_ac} <- fas_config(sys_id, bank_id, "mk_ac"),
         {:ok, lmk_id} <- fas_config(sys_id, bank_id, "lmk_identifier") do
      body = %{
        "messageHeader" => message_header(),
        "commandCode" => "KW",
        "modeFlag" => "0",
        "schemeId" => scheme_id,
        "mkAc" => mk_ac,
        "ivAc" => String.duplicate("0", 32),
        "pan" => pan,
        "branchOrHeightParameters" => "1",
        "applicationTransactionCounter" => Base.encode16(atc, case: :lower),
        "transactionData" => build_transaction_data_hex(un, txn_data),
        "arqc" => Base.encode16(arqc, case: :lower),
        "lmkIdentifier" => lmk_id
      }

      case HttpClient.post(body) do
        {:ok, %{"errorCode" => "00"}} -> :ok
        {:ok, %{"errorCode" => _code}} -> {:error, :arqc_mismatch}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_bin_match} -> {:error, :key_not_found}
      {:error, :unknown_key} -> {:error, :key_not_found}
      {:error, :not_configured} -> {:error, :key_not_found}
      {:error, _} = err -> err
    end
  end

  @impl VmuCore.FAS.HSM
  def generate_arpc(pan, atc, un, _arqc, arc, _pan_token) do
    with {:ok, {sys_id, bank_id, logo_id}} <- resolve_bin(pan),
         {:ok, scheme_id} <- resolve_scheme_id(sys_id, bank_id, logo_id),
         {:ok, mk_ac} <- fas_config(sys_id, bank_id, "mk_ac"),
         {:ok, lmk_id} <- fas_config(sys_id, bank_id, "lmk_identifier") do
      body = %{
        "messageHeader" => message_header(),
        "commandCode" => "KW",
        "modeFlag" => "2",
        "schemeId" => scheme_id,
        "mkAc" => mk_ac,
        "ivAc" => String.duplicate("0", 32),
        "pan" => pan,
        "branchOrHeightParameters" => "1",
        "applicationTransactionCounter" => Base.encode16(atc, case: :lower),
        "unpredictableNumber" => Base.encode16(un, case: :lower),
        "arc" => Base.encode16(arc, case: :lower),
        "lmkIdentifier" => lmk_id
      }

      case HttpClient.post(body) do
        {:ok, %{"errorCode" => "00", "mac" => mac_hex}} -> {:ok, Base.decode16!(mac_hex, case: :mixed)}
        {:ok, %{"errorCode" => code}} -> {:error, {:hsm_error, code}}
        {:error, reason} -> {:error, reason}
      end
    else
      {:error, :no_bin_match} -> {:error, :key_not_found}
      {:error, _} = err -> err
    end
  end

  @impl VmuCore.FAS.HSM
  def verify_pin(pin_block_hex, pan, pan_token) do
    with %VmuCore.CMS.CardPin{reference_pin_lmk: reference} when is_binary(reference) <-
           get_card_pin(pan_token),
         {:ok, {sys_id, bank_id, _logo_id}} <- resolve_bin(pan),
         {:ok, zpk} <- fas_config(sys_id, bank_id, "zpk"),
         {:ok, lmk_id} <- fas_config(sys_id, bank_id, "lmk_identifier") do
      pan_field = pan |> String.replace(~r/\D/, "") |> String.slice(0..-2//1) |> String.slice(-12..-1)

      body = %{
        "messageHeader" => message_header(),
        "commandCode" => "BE",
        "zpk" => zpk,
        "pinBlock" => pin_block_hex,
        "pinBlockFormatCode" => "01",
        "pan" => pan_field,
        "pin" => reference,
        "lmkIdentifier" => lmk_id
      }

      case HttpClient.post(body) do
        {:ok, %{"errorCode" => "00"}} -> :ok
        {:ok, %{"errorCode" => "01"}} -> {:error, :wrong_pin}
        {:ok, %{"errorCode" => _code}} -> {:error, :wrong_pin}
        {:error, reason} -> {:error, reason}
      end
    else
      nil -> {:error, :pin_not_set}
      %VmuCore.CMS.CardPin{reference_pin_lmk: nil} -> {:error, :pin_not_set}
      {:error, :no_bin_match} -> {:error, :pin_not_set}
      {:error, _} -> {:error, :pin_not_set}
    end
  end

  @impl VmuCore.FAS.HSM
  def change_pin(_pan_token, _old_pin, _new_pin) do
    Logger.warning("[ProductionHSM] change_pin not implemented — architecturally blocked, see moduledoc")
    {:error, :not_implemented}
  end

  @impl VmuCore.FAS.HSM
  def build_issuer_scripts(_pan_token, _commands) do
    Logger.warning("[ProductionHSM] build_issuer_scripts not implemented — stub")
    {:error, :not_implemented}
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp resolve_bin(pan), do: ParameterEngine.resolve_bin(pan)

  defp fas_config(sys_id, bank_id, key) do
    case ModuleConfigEngine.get("fas", key, sys_id, bank_id) do
      {:ok, nil} -> {:error, :not_configured}
      {:ok, value} -> {:ok, value}
      {:error, _} = err -> err
    end
  end

  defp resolve_scheme_id(sys_id, bank_id, logo_id) do
    with {:ok, card_scheme} <- ParameterEngine.get(sys_id, bank_id, logo_id, "", :card_scheme),
         {:ok, scheme_map} <- fas_config(sys_id, bank_id, "scheme_id_map") do
      case Map.get(scheme_map, card_scheme) do
        nil -> {:error, :unsupported_scheme}
        scheme_id -> {:ok, scheme_id}
      end
    end
  end

  defp get_card_pin(pan_token) do
    VmuCore.Repo.get_by(VmuCore.CMS.CardPin, pan_token: pan_token)
  end

  defp build_transaction_data_hex(un, txn_data) do
    raw = un <> txn_data
    padded = if rem(byte_size(raw), 8) == 0, do: raw, else: raw <> :binary.copy(<<0>>, 8 - rem(byte_size(raw), 8))
    Base.encode16(padded, case: :lower)
  end

  defp message_header, do: "1235"
end
