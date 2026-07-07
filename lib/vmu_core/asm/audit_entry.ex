defmodule VmuCore.ASM.AuditEntry do
  @moduledoc """
  Read schema over the append-only `cms_operator_audit` table (ASM-P4.1).

  The table predates ASM (migration `20260614000000`, written for the legacy
  `OperatorPortal` facade) — ASM adopts it as the single operator-audit sink
  rather than adding a second table. Writes go through
  `VmuCore.ASM.AuditLog.record/4` only; rows are never updated or deleted.
  """

  use Ecto.Schema

  schema "cms_operator_audit" do
    field :operator_id,   :string
    field :operator_role, :string
    field :action,        :string
    field :subject,       :string
    field :details,       :string
    field :performed_at,  :naive_datetime
    field :inserted_at,   :naive_datetime
  end
end
