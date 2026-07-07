defmodule VmuCore.Repo.Migrations.CreateFasReversalExceptions do
  @moduledoc """
  FAS-P6 (6B) — Unmatched reversal exception queue.

  When a 0400 reversal arrives but no matching fas_authorization can be found
  (by STAN+terminal_id or approval_code), the request is logged here for ops
  review rather than silently dropped. RC "25" (no match) is returned to the
  network, and the exception row drives the 8D admin queue.
  """

  use Ecto.Migration

  def change do
    create table(:fas_reversal_exceptions, primary_key: false) do
      add :id,           :binary_id, primary_key: true,
                         default: fragment("gen_random_uuid()")
      add :pan_token,    :string, size: 64
      add :mti,          :string, size: 4
      add :stan,         :string, size: 12
      add :rrn,          :string, size: 12
      add :terminal_id,  :string, size: 8
      add :approval_code, :string, size: 6
      add :raw_fields,   :map    # JSONB — full DE map for ops investigation
      # pending → escalated → resolved
      add :status,       :string, size: 20, null: false, default: "pending"

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:fas_reversal_exceptions, [:status],
      name: :fas_rev_exc_status_idx,
      where: "status = 'pending'")

    create index(:fas_reversal_exceptions, [:pan_token, :inserted_at],
      name: :fas_rev_exc_pan_idx)
  end
end
