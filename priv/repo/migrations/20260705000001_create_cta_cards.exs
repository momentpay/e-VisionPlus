defmodule VmuCore.Repo.Migrations.CreateCtaCards do
  use Ecto.Migration

  # CTA-P1 (docs/cta/CTA_Gap_Implementation_Tracker.md): first-class card
  # entity — one row per plastic GENERATION, so replacement/renewal history
  # is representable. Additive per ADR-CTA1 (cms_accounts stays the hot-path
  # card cache).
  def change do
    create table(:cta_cards, primary_key: false) do
      add :card_id,      :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,   references(:cms_accounts, column: :account_id, type: :uuid),
                         null: false
      add :pan_token,    :string, size: 64, null: false
      add :last_four,    :string, size: 4
      add :expiry,       :string, size: 4   # MMYY
      add :emboss_name,  :string, size: 26
      add :card_type,    :string, size: 15, null: false, default: "PRIMARY"
      # PRIMARY | SUPPLEMENTARY | VIRTUAL
      add :status,       :string, size: 12, null: false, default: "INACTIVE"
      # ORDERED | EMBOSSED | DISPATCHED | INACTIVE | ACTIVE
      # | BLOCKED | EXPIRED | REPLACED | DESTROYED
      add :block_reason, :string, size: 12   # LOST | STOLEN | FRAUD | DAMAGED | ADMIN
      # Plastic generation history
      add :generation,       :integer, null: false, default: 1
      add :replaces_card_id, :uuid    # prior generation this card supersedes
      add :activation_method, :string, size: 12  # ivr | first_use | app | admin
      add :dispatch_ref,     :string, size: 50   # courier tracking
      # Card-level channel controls (CTA-P3) — nil = inherit account/logo
      add :ecom_enabled,        :boolean
      add :atm_enabled,         :boolean
      add :contactless_enabled, :boolean
      add :intl_enabled,        :boolean
      # Lifecycle timestamps
      add :issued_at,    :utc_datetime
      add :activated_at, :utc_datetime
      add :blocked_at,   :utc_datetime
      add :expired_at,   :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create index(:cta_cards, [:account_id])
    create index(:cta_cards, [:status])
    create index(:cta_cards, [:replaces_card_id])
    # A pan_token can appear across generations (damaged-card replacement keeps
    # the PAN) but only ONE live card may hold it at a time.
    create unique_index(:cta_cards, [:pan_token],
             where: "status IN ('INACTIVE','ACTIVE','BLOCKED','ORDERED','EMBOSSED','DISPATCHED')",
             name: :cta_cards_active_pan_token_index)
  end
end
