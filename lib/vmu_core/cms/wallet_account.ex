defmodule VmuCore.CMS.WalletAccount do
  @moduledoc """
  Digital Wallet Phase W1 (2026-07-28) — a single-currency stored-value
  account belonging to a `CMS.WalletProduct`.

  Mirrors `CMS.DebitAccount`'s shape exactly (balance-based, own
  block-history/non-monetary-event tables) — NOT `CMS.Account`'s
  credit-shaped columns. This is a design correction from `docs/wallet/
  DIGITAL_WALLET_Module_Requirements.md`'s original `account_type:
  "WALLET"` recommendation (the Employee Card pattern): that reuse only
  works because Employee Card's own fields genuinely map onto
  `CMS.Account`'s credit-limit columns. A wallet has no credit line —
  it's stored value, structurally identical to what `CMS.PrepaidAccount`
  already is in this codebase.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:wallet_account_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[ACTIVE SUSPENDED CLOSED DORMANT]
  @valid_kyc_statuses ~w[PENDING VERIFIED REJECTED]

  schema "cms_wallet_accounts" do
    field :wallet_product_id, :binary_id
    field :customer_id,       :binary_id
    field :sys_id,            :string
    field :bank_id,           :string
    field :logo_id,           :string
    field :block_id,          :string

    field :available_balance, :decimal, default: Decimal.new(0)
    field :currency,          :string, default: "AED"
    field :status,            :string, default: "ACTIVE"
    field :opened_at,         :date
    field :closed_at,         :date

    field :block_code,        :string
    field :block_reason,      :string
    field :blocked_at,        :naive_datetime
    field :velocity_limits,   :map, default: %{}
    field :kyc_status,        :string, default: "PENDING"
    field :kyc_verified_at,   :naive_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w[wallet_product_id customer_id sys_id bank_id block_id logo_id opened_at]a
  @optional ~w[available_balance currency status closed_at
               block_code block_reason blocked_at velocity_limits
               kyc_status kyc_verified_at]a

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:kyc_status, @valid_kyc_statuses)
    |> validate_number(:available_balance, greater_than_or_equal_to: 0)
    |> unique_constraint([:wallet_product_id, :currency],
         name: :cms_wallet_accounts_wallet_product_id_currency_index,
         message: "this wallet already has an account in that currency")
  end

  def active?(%__MODULE__{status: "ACTIVE"}), do: true
  def active?(%__MODULE__{}), do: false
end
