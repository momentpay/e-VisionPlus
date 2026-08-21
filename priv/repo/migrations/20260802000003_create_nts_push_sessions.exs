defmodule VmuCore.Repo.Migrations.CreateNtsPushSessions do
  @moduledoc """
  NTS Phase F2 (2026-08-02) — tracks an in-flight MDES Token Connect
  browser-redirect provisioning attempt across the redirect-out/
  redirect-back boundary (Cases 1/3/5, see docs/nts/case-1..5). A
  fire-and-forget push (Case 2/Google Pay, Case 4/proprietary comms)
  never touches this table — only flows that round-trip through an
  external Token Requestor's own UI need session state.
  """

  use Ecto.Migration

  def change do
    create table(:nts_push_sessions, primary_key: false) do
      add :session_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :card_id, references(:cta_cards, type: :binary_id, column: :card_id, on_delete: :restrict), null: false
      add :customer_id, references(:cms_customers, type: :binary_id, column: :customer_id, on_delete: :restrict), null: false
      add :token_id, references(:nts_tokens, type: :binary_id, column: :token_id, on_delete: :restrict), null: false
      add :token_requestor_id, :string, size: 20, null: false
      add :direction, :string, size: 10, null: false, default: "push"
      add :push_account_receipt, :string, size: 100
      add :wallet_session_id, :string, size: 100
      add :wallet_callback_url, :string, size: 512
      add :status, :string, size: 20, null: false, default: "PENDING"
      add :requires_authentication, :boolean, null: false, default: false

      timestamps(type: :utc_datetime)
    end

    create index(:nts_push_sessions, [:card_id])
    create index(:nts_push_sessions, [:customer_id])
    create index(:nts_push_sessions, [:status])
  end
end
