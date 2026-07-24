defmodule VmuCore.Repo.Migrations.CreateCmsNotificationLog do
  use Ecto.Migration

  def change do
    # FR-070 — audit trail + idempotency guard for every outbound
    # payment-receipt notification attempt (VmuCore.CMS.Notification /
    # NotificationDispatcher). One row per (event, channel) pair, so the
    # same payment reference can fan out to several channels (email + sms)
    # without either one blocking or duplicating the other.
    create table(:cms_notification_log, primary_key: false) do
      add :notification_id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :account_id,      :uuid, null: false, references: :cms_accounts, type: :uuid
      add :event_type,      :string, size: 40, null: false
      # email | sms | whatsapp | webhook
      add :channel,         :string, size: 20, null: false
      add :content,         :text, null: false
      add :content_format,  :string, size: 20, null: false
      # low | normal | high | urgent
      add :priority,        :string, size: 20, null: false, default: "normal"
      # SENT | FAILED | SKIPPED (channel enabled but not configured with a
      # gateway URL yet — not an error, just nothing to do)
      add :status,          :string, size: 20, null: false
      add :response,        :map
      add :idempotency_key, :string, size: 150, null: false

      timestamps()
    end

    create unique_index(:cms_notification_log, [:idempotency_key])
    create index(:cms_notification_log, [:account_id])
  end
end
