defmodule VmuCore.Repo.Migrations.CreateNtsTokens do
  @moduledoc """
  Network Tokenization Service (NTS) Phase A (2026-07-29) — one row per
  scheme-issued device token (DPAN) provisioned for a card into a mobile
  wallet (Google Pay first; Apple/Samsung Pay stay stub). See
  docs/wallet/WALLET_Module_Requirements.md and the NTS implementation
  plan.

  `dpan` is stored in cleartext deliberately — see `VmuCore.NTS.Token`'s
  moduledoc for why (it's a different number from the real PAN, safe
  outside PCI scope by design of the scheme's tokenization itself).
  """

  use Ecto.Migration

  def change do
    create table(:nts_tokens, primary_key: false) do
      add :token_id, :binary_id, primary_key: true, default: fragment("gen_random_uuid()")
      add :card_id, references(:cta_cards, type: :binary_id, column: :card_id, on_delete: :restrict), null: false
      add :scheme, :string, size: 20, null: false
      add :wallet, :string, size: 20, null: false
      add :dpan, :string, size: 25
      add :token_requestor_id, :string, size: 50
      add :token_reference_id, :string, size: 50
      add :status, :string, size: 20, null: false, default: "PENDING"
      add :device_id, :string, size: 100
      add :device_name, :string, size: 100
      add :last_four, :string, size: 4
      add :provisioned_at, :utc_datetime
      add :suspended_at, :utc_datetime
      add :deleted_at, :utc_datetime

      timestamps(type: :utc_datetime)
    end

    create index(:nts_tokens, [:card_id])
    create index(:nts_tokens, [:dpan])
    create index(:nts_tokens, [:status])
  end
end
