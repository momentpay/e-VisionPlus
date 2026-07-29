defmodule VmuCore.NTS.Token do
  @moduledoc """
  A scheme-issued device token (DPAN) provisioned for a card into a mobile
  wallet — Network Tokenization Service Phase A (2026-07-29). See
  `docs/wallet/WALLET_Module_Requirements.md`.

  `dpan` is stored **in cleartext, deliberately** — this is not an
  oversight of this codebase's "PAN never stored raw" convention
  (`cta_cards.pan_token` is a one-way SHA-256 hash of the real PAN). A
  DPAN is a *different* number: the scheme (Mastercard MDES) issues it
  specifically so it's safe to hold outside PCI scope — MDES, not
  vmu_core, holds the DPAN↔real-PAN mapping. Do not "fix" this into a
  hash; that would break every DPAN lookup (`FAS.DpanCache`, once built)
  for no security benefit.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:token_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @schemes ~w[MASTERCARD VISA]
  @wallets ~w[GOOGLE_PAY APPLE_PAY SAMSUNG_PAY]
  @statuses ~w[PENDING ACTIVE SUSPENDED DELETED]

  schema "nts_tokens" do
    field :card_id,            :binary_id
    field :scheme,             :string
    field :wallet,             :string
    field :dpan,               :string
    field :token_requestor_id, :string
    field :token_reference_id, :string
    field :status,             :string, default: "PENDING"
    field :device_id,          :string
    field :device_name,        :string
    field :last_four,          :string
    field :provisioned_at,     :utc_datetime
    field :suspended_at,       :utc_datetime
    field :deleted_at,         :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w[card_id scheme wallet]a
  @optional ~w[dpan token_requestor_id token_reference_id status device_id device_name
               last_four provisioned_at suspended_at deleted_at]a

  def changeset(token, attrs) do
    token
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:scheme, @schemes)
    |> validate_inclusion(:wallet, @wallets)
    |> validate_inclusion(:status, @statuses)
  end

  def schemes, do: @schemes
  def wallets, do: @wallets
  def statuses, do: @statuses
end
