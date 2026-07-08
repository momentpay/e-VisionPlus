defmodule VmuCore.DPS.ConfigCatalog do
  @moduledoc """
  DPS module configuration catalog — resolves the open questions in
  `docs/dps/DPS_Module_Requirements.md` §6 as configurable settings rather than
  hardcoded defaults. See `VmuCore.Shared.ModuleConfigCatalog`.

  Not covered here: completing the arbitration flow (§6.4) is a state-machine/GL
  feature-completion task, not a config key.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "network_connectivity_mode",
        module: "dps",
        type: :map,
        allowed: nil,
        default: %{"VISA" => "manual", "MASTERCARD" => "manual"},
        scope: :bank,
        description:
          "Per-network dispute connectivity mode: \"manual\" (ops re-keys via network " <>
            "portal) or \"api\" (VROL/Mastercom integration). Both modes are supported; " <>
            "this selects which one applies per scheme."
      },
      %{
        key: "provisional_credit_window_days",
        module: "dps",
        type: :integer,
        allowed: nil,
        default: 10,
        scope: :bank,
        description: "Regulatory provisional-credit posting window, in days. Varies by customer/market."
      },
      %{
        key: "evidence_storage_backend",
        module: "dps",
        type: :enum,
        allowed: ~w[db s3 azure_blob],
        default: "db",
        scope: :bank,
        description: "Where dispute evidence documents are stored."
      },
      %{
        key: "evidence_storage_config",
        module: "dps",
        type: :map,
        allowed: nil,
        default: %{},
        scope: :bank,
        description:
          "Backend-specific storage settings (bucket/container name, region) when " <>
            "evidence_storage_backend is s3 or azure_blob. Stores a reference to " <>
            "credentials, never a raw secret."
      }
    ]
  end
end
