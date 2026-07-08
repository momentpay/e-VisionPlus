defmodule VmuCore.CTA.ConfigCatalog do
  @moduledoc """
  CTA module configuration catalog — resolves the open questions in
  `docs/cta/CTA_Module_Requirements.md` §6 as configurable settings rather than
  hardcoded defaults. See `VmuCore.Shared.ModuleConfigCatalog`.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "emboss_file_template",
        module: "cta",
        type: :map,
        allowed: nil,
        default: %{},
        scope: :logo,
        description:
          "Vendor emboss file record layout: uploaded field mapping template, applied " <>
            "when generating a vendor's batch emboss file. Empty map = no custom template " <>
            "configured (falls back to the built-in default layout)."
      },
      %{
        key: "emboss_delivery_channel",
        module: "cta",
        type: :enum,
        allowed: ~w[email sftp],
        default: "sftp",
        scope: :logo,
        description: "How the generated emboss batch file is delivered to the personalization bureau."
      },
      %{
        key: "emboss_encryption_method",
        module: "cta",
        type: :enum,
        allowed: ~w[pgp],
        default: "pgp",
        scope: :bank,
        description: "Encryption applied to emboss files before delivery. PGP is the only supported method today."
      },
      %{
        key: "card_replacement_pan_policy",
        module: "cta",
        type: :map,
        allowed: nil,
        default: %{"LOST" => "new", "STOLEN" => "new", "DAMAGED" => "same"},
        scope: :logo,
        description:
          "Reason-code → \"new\" | \"same\" PAN policy on card replacement. " <>
            "Default: lost/stolen always issue a new PAN; damaged keeps the same PAN."
      },
      %{
        key: "renewal_lead_time_days",
        module: "cta",
        type: :integer,
        allowed: nil,
        default: 30,
        scope: :logo,
        description: "Days before expiry that auto-renewal reissue is triggered."
      },
      %{
        key: "renewal_dormancy_suppression",
        module: "cta",
        type: :boolean,
        allowed: nil,
        default: true,
        scope: :logo,
        description: "When true, auto-renewal is skipped for dormant or blocked cards."
      },
      %{
        key: "wallet_tokenization_mode",
        module: "cta",
        type: :enum,
        allowed: ~w[disabled scheme_token own_token],
        default: "disabled",
        scope: :logo,
        description:
          "Digital wallet tokenization approach: disabled, scheme-based token service " <>
            "(Visa/Mastercard token service), or an own/proprietary token implementation."
      },
      %{
        key: "pin_set_channels_enabled",
        module: "cta",
        type: :list,
        allowed: ~w[ivr app web atm],
        default: ["ivr", "app"],
        scope: :bank,
        description: "Channels through which a cardholder may set/change their PIN."
      }
    ]
  end
end
