defmodule VmuCore.CMS.WalletTransfer do
  @moduledoc """
  A completed wallet-to-wallet transfer (Digital Wallet Phase W2,
  2026-07-28) — the single authoritative record of both legs.

  No pending/reserved state (unlike wallet-app's own `Transfer`, which
  models `:initiated → :reserved → :completed/:failed` for an
  eventually-consistent saga): this codebase's version is a single
  atomic Postgres transaction (`WalletTransferCommand.transfer/1`), so
  a row here only ever exists once both balance movements have already
  succeeded — `status` stays `"COMPLETED"` for v1, kept as a field for
  forward compatibility with a future async/multi-rail transfer type
  (A2A), not because this synchronous path needs it today.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w[COMPLETED FAILED]

  schema "cms_wallet_transfers" do
    field :from_wallet_account_id, :binary_id
    field :to_wallet_account_id,   :binary_id
    field :amount,                 :decimal
    field :currency,               :string
    field :status,                 :string, default: "COMPLETED"
    field :reason,                 :string
    field :initiated_by,           :string

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required ~w[from_wallet_account_id to_wallet_account_id amount currency initiated_by]a
  @optional ~w[status reason]a

  def changeset(transfer, attrs) do
    transfer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:reason, max: 255)
  end
end
