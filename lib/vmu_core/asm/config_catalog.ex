defmodule VmuCore.ASM.ConfigCatalog do
  @moduledoc """
  ASM module configuration catalog — resolves the open questions in
  `docs/asm/ASM_Module_Requirements.md` §6 as configurable settings rather than
  hardcoded defaults. See `VmuCore.Shared.ModuleConfigCatalog`.

  Not covered here: the role taxonomy question (§6.2) is a design task, not a config
  key — see the Module Configuration Framework doc's "Out of scope" note.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "authn_source",
        module: "asm",
        type: :list,
        allowed: ~w[local sso ad ldap],
        default: ["local"],
        scope: :bank,
        description:
          "Enabled authentication sources for this institution. A list rather than a " <>
            "single choice because deployments commonly run a corporate SSO/AD/LDAP " <>
            "source alongside a local-credential fallback."
      },
      %{
        key: "authn_provider_config",
        module: "asm",
        type: :map,
        allowed: nil,
        default: %{},
        scope: :bank,
        description:
          "Provider-specific connection settings for the enabled non-local authn " <>
            "sources (e.g. SSO issuer URL, LDAP host/base DN). Never stores raw secrets " <>
            "— reference a secrets manager key instead."
      },
      %{
        key: "pii_masking_rules",
        module: "asm",
        type: :map,
        allowed: nil,
        default: %{},
        scope: :system,
        description:
          "Role-wise PII field masking rules, keyed by \"<entity>.<field>\" (e.g. " <>
            "\"cif.national_id\") mapping to the roles that see the unmasked value and " <>
            "the mask pattern applied for everyone else."
      },
      %{
        key: "audit_retention_days",
        module: "asm",
        type: :integer,
        allowed: nil,
        default: 2555,
        scope: :system,
        description: "Regulatory retention period for operator audit logs, in days. Default is 7 years."
      }
    ]
  end
end
