defmodule VmuCore.Repo.Migrations.AddPrepaidAccountIdToCtaCards do
  @moduledoc """
  Way4 parity plan Phase 1 item 5 (Prepaid, P2). Third nullable FK on
  `cta_cards` alongside `account_id` (credit) / `debit_account_id`
  (Debit, item 4) — a prepaid card points here instead. `CTA.Card.
  changeset/2`'s "exactly one" invariant extends to cover all three.
  """

  use Ecto.Migration

  def change do
    alter table(:cta_cards) do
      add :prepaid_account_id, references(:cms_prepaid_accounts,
                                  column: :prepaid_account_id, type: :binary_id)
    end

    create index(:cta_cards, [:prepaid_account_id])
  end
end
