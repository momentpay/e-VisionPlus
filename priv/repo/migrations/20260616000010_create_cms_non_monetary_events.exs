defmodule VmuCore.Repo.Migrations.CreateCmsNonMonetaryEvents do
  @moduledoc """
  Sprint 2F: Create the cms_non_monetary_events audit table.

  Non-monetary events capture account maintenance changes that do not post
  to the GL — address updates, phone changes, billing cycle changes,
  card reissues, limit changes, etc.

  Each row is append-only: records are never updated or deleted. The
  old_value / new_value JSONB columns capture a before/after snapshot
  so the full audit trail is self-contained in this table.
  """

  use Ecto.Migration

  def change do
    create table(:cms_non_monetary_events, primary_key: false) do
      add :id,            :binary_id,  primary_key: true
      add :account_id,    references(:cms_accounts,
                            column:  :account_id,
                            type:    :binary_id,
                            on_delete: :restrict
                          ), null: false
      add :event_type,    :string,     size: 30,  null: false
      add :old_value,     :map                              # JSONB: before state
      add :new_value,     :map                              # JSONB: after state
      add :reason,        :string,     size: 255
      add :reference_id,  :string,     size: 50            # Call ID / ticket number
      add :operator_id,   :binary_id,                null: false
      add :operator_role, :string,     size: 20,  default: "AGENT"
      add :applied_at,    :naive_datetime,          null: false

      timestamps(updated_at: false)
    end

    # Primary query: all events for an account ordered by time
    create index(:cms_non_monetary_events, [:account_id, :applied_at],
      name: :cms_nme_account_time_idx
    )

    # Secondary: filter by event type within an account
    create index(:cms_non_monetary_events, [:account_id, :event_type, :applied_at],
      name: :cms_nme_account_type_idx
    )

    # Audit trail query: all events by operator
    create index(:cms_non_monetary_events, [:operator_id, :applied_at],
      name: :cms_nme_operator_idx
    )
  end
end
