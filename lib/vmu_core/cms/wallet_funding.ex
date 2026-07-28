defmodule VmuCore.CMS.WalletFunding do
  @moduledoc """
  A deposit/load transaction into a `WalletAccount` (Digital Wallet
  Phase W1, 2026-07-28). Mirrors `CMS.DebitFunding` exactly — same
  "data model now, real bank-rail integration later" posture: no live
  rail call exists anywhere in this codebase for any product yet.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_channels ~w[INTERNAL_TRANSFER ADMIN_MANUAL EXTERNAL_BANK_TRANSFER CASH_DEPOSIT]

  schema "cms_wallet_fundings" do
    field :wallet_account_id,  :binary_id
    field :amount,             :decimal
    field :channel,            :string
    field :external_reference, :string
    field :posted_by,          :string
    field :ledger_entry_id,    :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w[wallet_account_id amount channel posted_by]a
  @optional ~w[external_reference ledger_entry_id]a

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:channel, @valid_channels)
    |> validate_number(:amount, greater_than: 0)
    |> validate_external_reference()
    |> unique_constraint(:external_reference,
         name: :cms_wallet_fundings_external_reference_index)
  end

  defp validate_external_reference(changeset) do
    case get_field(changeset, :channel) do
      c when c in ["EXTERNAL_BANK_TRANSFER", "CASH_DEPOSIT"] ->
        validate_required(changeset, [:external_reference])
      _ ->
        changeset
    end
  end
end
