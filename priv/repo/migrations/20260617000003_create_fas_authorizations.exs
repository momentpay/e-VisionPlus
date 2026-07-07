defmodule VmuCore.Repo.Migrations.CreateFasAuthorizations do
  @moduledoc """
  Phase 1 — FAS Foundation.

  Durable auth history. Every authorization decision — approve or decline —
  is written here asynchronously after the response is sent. Serves as:
    - Source for STAN duplicate detection
    - Clearing match anchor (approval_code / RRN)
    - Reversal lookup (Phase 6)
    - Audit trail and ops reporting
  """

  use Ecto.Migration

  def change do
    create table(:fas_authorizations, primary_key: false) do
      add :id,            :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :pan_token,     :string, size: 64,  null: false   # SHA-256 hex of raw PAN
      add :account_id,    :binary_id                        # nil if BIN/PAN not found
      add :logo_id,       :string, size: 4
      add :sys_id,        :string, size: 4
      add :amount,        :decimal, precision: 18, scale: 2, null: false
      add :currency,      :string, size: 3, null: false, default: "000"
      add :mcc,           :string, size: 4
      add :channel,       :string, size: 20, null: false, default: "pos"
      add :mti,           :string, size: 4, null: false, default: "0100"
      add :rc,            :string, size: 2, null: false
      add :approval_code, :string, size: 6                  # nil on decline
      add :stan,          :string, size: 6
      add :rrn,           :string, size: 12
      add :terminal_id,   :string, size: 8
      add :merchant_id,   :string, size: 15
      add :stip_used,     :boolean, null: false, default: false
      add :risk_score,    :float                             # from mw_risk (Phase 2)
      add :decision_path, :map, null: false, default: %{}   # JSONB audit of rule path

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    # Hot path: duplicate STAN detection within 60s window
    create index(:fas_authorizations, [:stan, :terminal_id, :pan_token],
      name: :fas_auth_stan_terminal_pan_idx)

    # Clearing match by approval_code / RRN (Phase 4)
    create index(:fas_authorizations, [:approval_code],
      name: :fas_auth_approval_code_idx,
      where: "approval_code IS NOT NULL")

    create index(:fas_authorizations, [:rrn],
      name: :fas_auth_rrn_idx,
      where: "rrn IS NOT NULL")

    # Account history queries
    create index(:fas_authorizations, [:account_id, :inserted_at],
      name: :fas_auth_account_inserted_idx,
      where: "account_id IS NOT NULL")

    # Pan token + time range queries
    create index(:fas_authorizations, [:pan_token, :inserted_at],
      name: :fas_auth_pan_token_inserted_idx)
  end
end
