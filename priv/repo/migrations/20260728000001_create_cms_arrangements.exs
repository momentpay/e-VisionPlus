defmodule VmuCore.Repo.Migrations.CreateCmsArrangements do
  @moduledoc """
  Koṣa domain-model alignment (`docs/cms/core-domain-new-docs.md`,
  2026-07-28 architecture discussion) — the Arrangement layer: one row
  per customer-relationship, indexing across all four existing product
  tables without changing any of them. Deliberately thin: no `status`
  field, no balance — those stay authoritative on the real product
  table (`CMS.Account`/`DebitAccount`/`PrepaidAccount`/`HCS.
  EmployeeCard`/`FleetCard`), read live via `account_ref`, never
  duplicated here where they could drift (the same "field exists,
  nothing keeps it in sync" bug class this whole project has hit
  repeatedly — LMS, HCS, DPS).

  `account_ref` has no DB-level FK — it's polymorphic (points at
  whichever table `product_type` says), same convention already used by
  `cms_ledger_entries.account_id`/`fas_pending_holds.account_id` for
  the identical cross-schema-reuse reason. Stored as a plain `:string`,
  not `:binary_id` — found live while wiring this in: `CMS.Account`/
  `DebitAccount`/`PrepaidAccount` all key on UUID, but `HCS.Company`/
  `EmployeeCard`/`FleetCard` predate that convention and use plain
  integer primary keys, so a single strongly-typed column can't hold
  both.
  """

  use Ecto.Migration

  def change do
    create table(:cms_arrangements, primary_key: false) do
      add :id,           :binary_id, primary_key: true,
                          default: fragment("gen_random_uuid()")
      add :customer_id,  :binary_id, null: false
      # CREDIT | DEBIT | PREPAID | CORPORATE_FACILITY | CORPORATE_EMPLOYEE | CORPORATE_FLEET
      add :product_type, :string, size: 30, null: false
      add :account_ref,  :string, null: false
      add :opened_at,    :date, null: false

      timestamps(type: :utc_datetime)
    end

    create index(:cms_arrangements, [:customer_id])
    create unique_index(:cms_arrangements, [:product_type, :account_ref])
  end
end
