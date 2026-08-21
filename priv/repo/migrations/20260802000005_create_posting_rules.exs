defmodule VmuCore.Repo.Migrations.CreatePostingRules do
  @moduledoc """
  GL Phase A2 — posting rules as data.

  Replaces the hardcoded account pairs currently spread across
  `CMS.InternalGlPoster` (13 functions, each with its accounts inline) and
  `FAS.GL.CardAccountCodes.journal_pair/1` (6 clauses).

  ## Why every rule carries two account pairs

  The live code posts against a chart that **conflicts with the reconciled
  one** — 5001/5002/5003 for stored value (5001 and 5002 are expense accounts
  in the reconciled chart), 2001 for interest income (a liability there),
  1006 for cash clearing (HCS's receivable there). See
  `VmuCore.GL.ChartOfAccounts.conflicts/0`.

  Seeding only the reconciled codes would bake a silent behaviour change into
  Phase A, which is supposed to be build-only. Seeding only the legacy codes
  would bake the collision into the new module permanently.

  So each rule carries both:

    * `legacy_dr_account` / `legacy_cr_account` — exactly what fires today.
      Phase B shadow-writes with these so the diff against `cms_ledger_entries`
      is byte-for-byte.
    * `dr_account` / `cr_account` — the reconciled target. Phase C flips call
      sites onto these one at a time.

  The remapping is then a reviewable data change with an audit trail, not a
  code rewrite. Nothing reads this table yet.
  """
  use Ecto.Migration

  def change do
    create table(:posting_rules) do
      add :event_type,   :string, size: 30, null: false
      add :product,      :string, size: 20, null: false

      # Reconciled target accounts (Phase C onward)
      add :dr_account,   references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false
      add :cr_account,   references(:gl_accounts, column: :code, type: :string, on_delete: :restrict),
          null: false

      # What the live code posts today. NULL when it already matches the
      # reconciled pair — so a non-null value is precisely "this rule still
      # needs a Phase C cutover".
      add :legacy_dr_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict)
      add :legacy_cr_account, references(:gl_accounts, column: :code, type: :string, on_delete: :restrict)

      # Value written to cms_ledger_entries.transaction_code by the current
      # code. Not always equal to event_type — wallet withdrawal posts as
      # "PURCHASE", and both adjustment directions post as "ADJUSTMENT".
      add :legacy_transaction_code, :string, size: 20, null: false

      add :narrative_template, :string, null: false
      add :source_module,      :string, size: 30, null: false
      add :active,             :boolean, null: false, default: true
      add :notes,              :text

      timestamps(type: :utc_datetime)
    end

    create unique_index(:posting_rules, [:event_type, :product])
    create index(:posting_rules, [:source_module])

    # A rule may not debit and credit the same account — that is a no-op
    # posting and always a configuration mistake.
    create constraint(:posting_rules, :posting_rules_distinct_accounts_check,
             check: "dr_account <> cr_account")

    # Legacy pair must be supplied as a pair or not at all.
    create constraint(:posting_rules, :posting_rules_legacy_pair_check,
             check: """
             (legacy_dr_account IS NULL AND legacy_cr_account IS NULL)
             OR
             (legacy_dr_account IS NOT NULL AND legacy_cr_account IS NOT NULL)
             """)
  end
end
