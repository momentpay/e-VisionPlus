defmodule VmuCore.Repo.Migrations.CreateSupplementaryCards do
  @moduledoc """
  Sprint 2C: Supplementary (additional) card relationships.

  VisionPlus supports multiple cards on a single credit account:
    - PRIMARY   — the main cardholder account card
    - SUPPLEMENTARY — additional card issued to a second person
                      (spouse, employee, etc.) linked to the primary account

  Each supplementary card is itself a CMS account (cms_accounts row) but with a
  different PAN and possibly a different sub_limit. This table records the
  parent ↔ child relationship between account records.

  ## Model

  primary_account_id    — the "parent" CMS account (holds the full credit limit)
  supplementary_account_id — the "child" CMS account (sub-limited cardholder)
  relationship_type     — SUPPLEMENTARY (all current cases)
  sub_limit             — optional spending limit imposed on the supplementary card
                          (nil = no additional restriction beyond primary OTB)
  status                — ACTIVE | SUSPENDED | CLOSED
  activated_at          — when the supplementary card was first activated

  ## Billing

  All balances from supplementary card transactions accrue to the primary account's
  balance buckets. The supplementary account has its own PAN and block codes but
  shares the primary account's credit limit and billing cycle.
  """

  use Ecto.Migration

  def change do
    create table(:supplementary_cards, primary_key: false) do
      add :id,
          :binary_id,
          primary_key: true,
          default: fragment("gen_random_uuid()")

      add :primary_account_id,
          references(:cms_accounts,
            type: :binary_id,
            column: :account_id,
            on_delete: :restrict),
          null: false

      add :supplementary_account_id,
          references(:cms_accounts,
            type: :binary_id,
            column: :account_id,
            on_delete: :restrict),
          null: false

      # SUPPLEMENTARY is the only type now; reserved for future types (EMPLOYEE, VIRTUAL)
      add :relationship_type, :string, size: 20, null: false, default: "SUPPLEMENTARY"

      # Optional spending sub-limit for this supplementary card (nil = unrestricted)
      add :sub_limit,   :decimal, precision: 18, scale: 2

      add :status,      :string, size: 10, null: false, default: "ACTIVE"
      add :activated_at, :naive_datetime

      timestamps()
    end

    # Each supplementary account can only have one primary (cannot be child of multiple parents)
    create unique_index(:supplementary_cards, [:supplementary_account_id],
             name: :supplementary_cards_child_unique_idx)

    # List all supplementary cards for a primary account
    create index(:supplementary_cards, [:primary_account_id, :status],
             name: :supplementary_cards_primary_idx)

    # Constraint: a primary account cannot be its own supplementary
    create constraint(:supplementary_cards, :no_self_reference,
             check: "primary_account_id != supplementary_account_id")
  end
end
