defmodule VmuCore.ASM.RoleTaxonomy do
  @moduledoc """
  Recommended role staffing per bank size tier (ASM role taxonomy design,
  `docs/asm/ASM_Role_Taxonomy.md`).

  Advisory only — `VmuCore.ASM.RolePermission`'s grants are unchanged and identical
  across every tier; this module only informs the operator-creation UI which of the
  existing 7 roles a bank of a given `org_size` should typically staff. It does not
  restrict which role can actually be assigned.
  """

  @recommended %{
    "LARGE"  => ~w[TELLER CS_AGENT OPS SUPERVISOR RISK COMPLIANCE ADMIN],
    "MEDIUM" => ~w[CS_AGENT OPS SUPERVISOR COMPLIANCE ADMIN],
    "SMALL"  => ~w[CS_AGENT SUPERVISOR COMPLIANCE ADMIN]
  }

  @doc "Recommended roles for a bank's org_size (\"SMALL\"/\"MEDIUM\"/\"LARGE\"). Empty list if unknown/nil."
  @spec recommended_roles(String.t() | nil) :: [String.t()]
  def recommended_roles(org_size), do: Map.get(@recommended, org_size, [])

  @doc "Short human-readable staffing note for a bank's org_size, or nil if unknown."
  @spec hint(String.t() | nil) :: String.t() | nil
  def hint(nil), do: nil

  def hint(org_size) do
    case recommended_roles(org_size) do
      [] ->
        nil

      roles ->
        label = org_size |> String.downcase() |> String.capitalize()
        "This bank is sized #{label} — recommended roles: #{Enum.join(roles, ", ")}."
    end
  end
end
