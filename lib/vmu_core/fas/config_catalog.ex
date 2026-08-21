defmodule VmuCore.FAS.ConfigCatalog do
  @moduledoc """
  FAS module configuration catalog — the key material `ProductionHSM`
  needs to talk to the real vendor HSM (Way4 parity plan Phase 0 item 7,
  2026-07-24). Every value here is either already LMK-encrypted (safe to
  store outside the HSM — useless without the LMK that lives inside it)
  or a public key (safe by construction) — never a raw secret.

  Bank-scoped, matching how a real HSM deployment provisions one set of
  working keys per issuing institution. See `VmuCore.FAS.HSM.
  ProductionHSM`'s moduledoc for which commands consume which key.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "cvk",
        module: "fas",
        type: :string,
        allowed: nil,
        default: nil,
        scope: :bank,
        description:
          "Card Verification Key, LMK-encrypted, used by ProductionHSM.verify_cvv/4 (CY " <>
            "command). Generated/provisioned once by security officers on the real HSM " <>
            "console — never derivable from anything in this codebase."
      },
      %{
        key: "mk_ac",
        module: "fas",
        type: :string,
        allowed: nil,
        default: nil,
        scope: :bank,
        description:
          "Issuer Master Key for Application Cryptograms, LMK-encrypted, used by " <>
            "ProductionHSM.verify_arqc/6 and generate_arpc/6 (KW command)."
      },
      %{
        key: "zpk",
        module: "fas",
        type: :string,
        allowed: nil,
        default: nil,
        scope: :bank,
        description:
          "Zone PIN Key, LMK-encrypted, under which an interchange-sourced DE52 PIN " <>
            "block is encrypted — used by ProductionHSM.verify_pin/3 (BE command). This " <>
            "is the switch/network's zone key for this bank, not a per-card value."
      },
      %{
        key: "lmk_identifier",
        module: "fas",
        type: :string,
        allowed: nil,
        default: "00",
        scope: :bank,
        description: "LMK identifier for this bank's HSM partition, per the vendor's provisioning."
      },
      %{
        key: "scheme_id_map",
        module: "fas",
        type: :map,
        allowed: nil,
        default: %{"VISA" => "0", "MASTERCARD" => "1"},
        scope: :bank,
        description:
          "LogoParameter.card_scheme (VISA/MASTERCARD/...) -> KW's numeric Scheme ID. " <>
            "Only VISA/MASTERCARD (EMV Option A, EMV2000 session key derivation) are " <>
            "mapped by default — the common case; other schemes need their own Scheme " <>
            "ID + key-derivation-method combination added here before use, never guessed."
      }
    ]
  end
end
