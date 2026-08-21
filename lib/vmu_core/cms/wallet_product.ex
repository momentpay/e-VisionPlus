defmodule VmuCore.CMS.WalletProduct do
  @moduledoc """
  Digital Wallet Phase W1 (2026-07-28) — the customer-facing "wallet"
  grouping concept, holding N single-currency `CMS.WalletAccount` rows.

  This is the multi-currency answer from `docs/wallet/
  DIGITAL_WALLET_Module_Requirements.md` §4: wallet-app's own real
  `WalletProduct`/`CurrencyConfig` design achieves multi-currency by
  composing single-currency sub-accounts under one product, not by
  making a single account row multi-currency — compatible with this
  codebase's own ADR-C4 (`CMS.Account` stays single-currency) without
  reversing it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:wallet_product_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[ACTIVE SUSPENDED CLOSED]

  schema "cms_wallet_products" do
    field :customer_id, :binary_id
    field :name, :string
    field :status, :string, default: "ACTIVE"

    timestamps(type: :utc_datetime)
  end

  @required [:customer_id, :name]
  @optional [:status]

  def changeset(product, attrs) do
    product
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:name, max: 100)
  end
end
