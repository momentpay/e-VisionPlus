defmodule VmuCore.Repo.Migrations.AddDebitAccountIdToCtaCards do
  @moduledoc """
  Way4 parity plan Phase 1 item 4 (Debit, D1). `cta_cards.account_id` has
  a real DB-level FK to `cms_accounts` — a debit card cannot reuse it
  without either weakening that FK or faking a placeholder `cms_accounts`
  row per debit account. Adds a parallel nullable FK instead, same
  pattern as `hcs_spending_controls.fleet_card_id` alongside
  `employee_card_id` (Phase 1 item 3) — "exactly one of account_id /
  debit_account_id is set" is enforced at the application layer in
  `CTA.Card.changeset/2`, not a DB CHECK constraint, matching this
  repo's existing convention for this class of invariant.
  """

  use Ecto.Migration

  def up do
    execute "ALTER TABLE cta_cards ALTER COLUMN account_id DROP NOT NULL"

    alter table(:cta_cards) do
      add :debit_account_id, references(:cms_debit_accounts,
                                column: :debit_account_id, type: :binary_id)
    end

    create index(:cta_cards, [:debit_account_id])
  end

  def down do
    drop index(:cta_cards, [:debit_account_id])

    alter table(:cta_cards) do
      remove :debit_account_id
    end

    execute "ALTER TABLE cta_cards ALTER COLUMN account_id SET NOT NULL"
  end
end
