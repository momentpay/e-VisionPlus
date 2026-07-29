defmodule VmuCore.Repo.Migrations.CreateAsmServiceAccounts do
  use Ecto.Migration

  @moduledoc """
  A1.1 (2026-07-12) — service-account identity for the new vmu_core API
  layer (workstream A1). Reuses ASM's operator-identity primitives (this
  table lives in ASM, not a new "api" module) rather than inventing a
  parallel auth system, per the reviewed decision to reuse ASM
  service-account tokens.

  Distinct from `asm_operators`: operators are human, PBKDF2-password,
  session-cookie logins; service accounts are machine callers (wallet-app,
  and future consumers), bearer-token, no session, no password policy.
  """

  def change do
    create table(:asm_service_accounts, primary_key: false) do
      add :service_account_id, :binary_id, primary_key: true
      add :name,               :string, null: false
      add :token_hash,         :string, null: false
      add :scopes,             {:array, :string}, null: false, default: []
      add :status,             :string, null: false, default: "ACTIVE"
      add :last_used_at,       :utc_datetime
      add :created_by,         :string

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:asm_service_accounts, [:token_hash])
    create unique_index(:asm_service_accounts, [:name])
  end
end
