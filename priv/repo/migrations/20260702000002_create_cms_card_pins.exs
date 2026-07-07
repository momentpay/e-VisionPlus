defmodule VmuCore.Repo.Migrations.CreateCmsCardPins do
  @moduledoc """
  FAS-P7 (7E) — Card PIN storage for issuer-side PIN verification.

  Stores PBKDF2-SHA256 hashed PINs indexed by pan_token. The plaintext PIN
  never persists — only the hash + salt are stored.

  try_counter and pin_locked_at implement the ISO 9564 PIN try counter:
  - Incremented on each wrong PIN attempt (via SoftHSM / ProductionHSM)
  - Reset to 0 on correct PIN
  - Lock (set pin_locked_at) when try_counter reaches the logo-level max
    (default 3). Locked PINs cause RC "75" (PIN tries exceeded) on all
    subsequent PIN-bearing requests for that card.

  PIN records are created during card personalisation / PIN mailer generation
  (CTA phase, out of scope for FAS-P7 but the schema is ready here).
  """

  use Ecto.Migration

  def change do
    create table(:cms_card_pins, primary_key: false) do
      add :id,           :binary_id, primary_key: true,
                         default: fragment("gen_random_uuid()")
      add :pan_token,    :string, size: 64, null: false
      add :pin_hash,     :string, size: 64, null: false   # PBKDF2-SHA256, hex-encoded
      add :pin_salt,     :string, size: 32, null: false   # 16-byte random salt, hex-encoded
      add :try_counter,  :integer, null: false, default: 0
      add :pin_locked_at, :utc_datetime

      timestamps(type: :utc_datetime_usec, updated_at: false)
    end

    create unique_index(:cms_card_pins, [:pan_token], name: :cms_card_pins_pan_token_idx)

    create index(:cms_card_pins, [:pan_token, :pin_locked_at],
      name: :cms_card_pins_locked_idx,
      where: "pin_locked_at IS NOT NULL")
  end
end
