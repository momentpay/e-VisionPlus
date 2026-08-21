defmodule VmuCore.Repo.Migrations.AddInstitutionToPostingSets do
  @moduledoc """
  GL Phase A5 — `posting_sets` carries the institution it belongs to.

  Which SYS/BANK's books an execution lands in is a property of the execution,
  not context to be threaded around it. Both the period gate
  (`GL.Periods.validate_gl_date/3`) and GL consolidation key on it, and the
  banking date recorded on the set is only meaningful alongside the
  institution it came from.

  Nullable because Phase A wrote rows before this column existed; the
  RuleEngine always populates it.
  """
  use Ecto.Migration

  def change do
    alter table(:posting_sets) do
      add :sys_id,  :string, size: 4
      add :bank_id, :string, size: 4
    end

    create index(:posting_sets, [:sys_id, :bank_id, :gl_date])
  end
end
