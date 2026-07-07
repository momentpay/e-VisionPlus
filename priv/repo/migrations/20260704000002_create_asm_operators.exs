defmodule VmuCore.Repo.Migrations.CreateAsmOperators do
  use Ecto.Migration

  # ASM-P1 (docs/asm/ASM_Implementation_Tracker.md): operator identity core.
  # Local credentials first (ADR-A1); SSO/LDAP later behind the same context.
  def change do
    create table(:asm_operators, primary_key: false) do
      add :operator_id,     :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :username,        :string, size: 40, null: false
      add :display_name,    :string, size: 80, null: false
      add :pw_hash,         :string, size: 64, null: false   # PBKDF2-SHA256 hex
      add :pw_salt,         :string, size: 32, null: false
      add :role,            :string, size: 20, null: false, default: "CS_AGENT"
      # TELLER | CS_AGENT | OPS | SUPERVISOR | RISK | COMPLIANCE | ADMIN
      add :status,          :string, size: 12, null: false, default: "ACTIVE"
      # ACTIVE | LOCKED | DISABLED
      add :bank_scope,      :string, size: 4   # nil = all banks; else restrict to bank_id
      add :failed_attempts, :smallint, null: false, default: 0
      add :locked_at,       :utc_datetime
      add :last_login_at,   :utc_datetime
      add :password_changed_at, :utc_datetime

      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:asm_operators, [:username])
    create index(:asm_operators, [:status])

    # Every authentication attempt, success or failure (FR-ASM-008)
    create table(:asm_login_audit, primary_key: false) do
      add :id,          :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :username,    :string, size: 40, null: false
      add :operator_id, :uuid   # nil when username unknown
      add :outcome,     :string, size: 20, null: false
      # success | bad_password | locked | disabled | unknown_user
      add :ip_address,  :string, size: 45

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create index(:asm_login_audit, [:username, :inserted_at])
    create index(:asm_login_audit, [:outcome])
  end
end
