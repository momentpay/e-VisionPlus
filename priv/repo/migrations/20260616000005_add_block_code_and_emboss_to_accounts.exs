defmodule VmuCore.Repo.Migrations.AddBlockCodeAndEmbossToAccounts do
  @moduledoc """
  Sprint 2A + 2B:
    - Add block_code (distinct from account_status) to cms_accounts.
    - Add emboss_name (card face name, max 26 chars) to cms_accounts.

  ## block_code vs account_status

  VisionPlus distinguishes between the account lifecycle status (ACTIVE/CLOSED/
  SUSPENDED) and the operational block reason. An account can be ACTIVE in
  lifecycle but blocked for a specific reason:

    L — Lost card
    S — Stolen card
    F — Fraud suspicion
    C — Collectable (collections hold)
    O — Overlimit restriction
    blank / nil — No block applied

  Multiple block codes can apply simultaneously in VisionPlus; this schema
  captures the primary (most recent) block code. Full block history is in
  the `block_code_history` table.

  ## emboss_name

  The name printed on the physical card face. Max 26 characters, uppercase.
  Standard format: "FIRSTNAME LASTNAME" or "COMPANY NAME" for corporate cards.
  Synced from CTA embossing order on card creation.
  """

  use Ecto.Migration

  def change do
    alter table(:cms_accounts) do
      # Primary block code — nil means no block active
      # Values: L=Lost, S=Stolen, F=Fraud, C=Collections, O=Overlimit
      add :block_code,   :string, size: 2
      # Reason text for the current block (free text, operator-entered)
      add :block_reason, :string, size: 100
      # When the current block was applied
      add :blocked_at,   :naive_datetime
      # Card face emboss name (synced from CTA embossing order)
      add :emboss_name,  :string, size: 26
    end

    # Index for operations: find all blocked accounts in a logo
    create index(:cms_accounts, [:block_code],
             name: :cms_accounts_block_code_idx,
             where: "block_code IS NOT NULL")
  end
end
