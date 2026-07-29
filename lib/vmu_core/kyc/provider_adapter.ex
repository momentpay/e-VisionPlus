defmodule VmuCore.Kyc.ProviderAdapter do
  @moduledoc """
  Behaviour for pluggable KYC document/field providers (KYC-P3,
  `docs/kyc/KYC_Implementation_Tracker.md` §7). One adapter behaviour, N
  implementations — the intentional alternative to the MMS reference's four
  parallel, never-reconciled validation systems
  (`docs/kyc/MMS_KYC_Feature_Reference.md` §4). Confirmed with the user
  2026-07-29: "keep multiple option open as per architecture... we might
  need to depend on 3rd party provider... so we can add other provider
  later as per need."

  `extract_text/1` is OCR extraction from an uploaded document (one real
  implementation ships now: `VmuCore.Kyc.Adapters.OcrHttpAdapter`).
  `validate_field/2` is for identity/screening providers (Signzy/LSEG-
  equivalent) — no concrete implementation yet, deliberately: this phase
  only needed OCR to be real. The callback exists now so a real provider
  can be added later without touching `Kyc.Documents` or any caller.
  """

  @doc "Extract text from a document file at `path`. Returns provider-shaped result data."
  @callback extract_text(path :: String.t()) :: {:ok, map()} | {:error, term()}

  @doc "Validate a single field's value against an external identity/screening provider."
  @callback validate_field(field :: map(), value :: term()) :: {:ok, map()} | {:error, term()}

  @optional_callbacks validate_field: 2
end
