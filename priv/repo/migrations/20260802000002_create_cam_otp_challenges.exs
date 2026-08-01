defmodule VmuCore.Repo.Migrations.CreateCamOtpChallenges do
  @moduledoc """
  Cardholder Access (CAM) Phase F1 (2026-08-02) — one-time-code login
  challenges for the new cardholder-facing mobile-OTP authentication
  (`VmuCore.CAM`). `code_hash` only — the raw code is never persisted,
  same discipline as `ASM.ServiceAccount.token_hash`.
  """

  use Ecto.Migration

  def change do
    create table(:cam_otp_challenges, primary_key: false) do
      add :otp_challenge_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :customer_id, references(:cms_customers, type: :binary_id, column: :customer_id, on_delete: :delete_all), null: false
      add :purpose, :string, size: 20, null: false, default: "LOGIN"
      add :code_hash, :string, size: 64, null: false
      add :attempts, :integer, null: false, default: 0
      add :expires_at, :utc_datetime, null: false
      add :consumed_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:cam_otp_challenges, [:customer_id])
  end
end
