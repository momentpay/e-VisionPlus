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
          "Vendor emboss file record layout overrides — field widths (pan_width, " <>
            "expiry_width, name_width, service_code, sequence_width, cvc2_width, " <>
            "track2_width, logo_id_width, record_length), merged over the built-in " <>
            "128-char default layout in EmbossingFileGenerator. Empty map = built-in " <>
            "layout unchanged. v1 supports width/value overrides, not field reordering " <>
            "or a full upload-and-map wizard (see Module_Configuration_Framework.md §6)."
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
        default: %{"LOST" => "new", "STOLEN" => "new", "FRAUD" => "new", "DAMAGED" => "same"},
        scope: :logo,
        description:
          "Reason-code → \"new\" | \"same\" PAN policy on card replacement. " <>
            "Default: lost/stolen/fraud always issue a new PAN; damaged keeps the same PAN. " <>
            "A reason code absent from the map falls back to the same lost/stolen/fraud=new rule."
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
        description:
          "Channels through which a cardholder may set/change their PIN. Wired for " <>
            "\"ivr\" (VmuCore.IVR.IvrSession); \"app\"/\"web\"/\"atm\" have no PIN-change " <>
            "endpoint yet, so including them here has no effect until one exists."
      }
    ]
  end
end
