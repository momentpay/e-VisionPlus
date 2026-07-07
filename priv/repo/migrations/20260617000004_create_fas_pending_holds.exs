defmodule VmuCore.Repo.Migrations.CreateFasPendingHolds do
  @moduledoc """
  Phase 1 — FAS Foundation.

  Durable pending authorizations (holds) that reduce account OTB until:
    - Cleared by a matching settlement record (Phase 4)
    - Reversed by a 0400 message (Phase 6)
    - Expired (hold_type-specific TTL, typically 7 days)

  Replaces the in-memory-only OTB reduction in AccountStateCoordinator,
  ensuring holds survive process restarts.
  """

  use Ecto.Migration

  def change do
    create table(:fas_pending_holds, primary_key: false) do
      add :id,                   :binary_id, primary_key: true,
                                 default: fragment("gen_random_uuid()")
      add :fas_authorization_id, :binary_id, null: false
      add :account_id,           :binary_id, null: false
      add :hold_amount,          :decimal, precision: 18, scale: 2, null: false
      # standard | hotel | fuel | preauth | incremental
      add :hold_type,            :string, size: 20, null: false, default: "standard"
      add :expires_at,           :utc_datetime, null: false
      add :cleared_at,           :utc_datetime   # set when clearing match found (Phase 4)
      add :reversal_at,          :utc_datetime   # set when 0400 reversal processed (Phase 6)

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:fas_pending_holds, [:fas_authorization_id],
      name: :fas_holds_auth_id_idx)

    create index(:fas_pending_holds, [:account_id],
      name: :fas_holds_account_idx,
      where: "cleared_at IS NULL AND reversal_at IS NULL")

    # Hold aging monitor — expired but not cleared (Phase 8)
    create index(:fas_pending_holds, [:expires_at],
      name: :fas_holds_expiry_idx,
      where: "cleared_at IS NULL AND reversal_at IS NULL")
  end
end
