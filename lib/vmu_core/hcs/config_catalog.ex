defmodule VmuCore.HCS.ConfigCatalog do
  @moduledoc """
  HCS module configuration (Way4 parity plan Phase 1 item 2, 2026-07-25)
  — the facility limit change approval matrix, same role-list-gate shape
  as COL's `writeoff_approval_matrix`/`workout_approval_matrix`.
  """

  @spec entries() :: [VmuCore.Shared.ModuleConfigCatalog.spec()]
  def entries do
    [
      %{
        key: "facility_limit_approval_matrix",
        module: "hcs",
        type: :list,
        allowed: ~w[TELLER CS_AGENT OPS SUPERVISOR RISK COMPLIANCE ADMIN],
        default: ~w[SUPERVISOR RISK],
        scope: :bank,
        description:
          "Which ASM roles may approve an HCS company facility limit change " <>
            "request (role-list gate; ADMIN always qualifies regardless of this list)."
      }
    ]
  end
end
