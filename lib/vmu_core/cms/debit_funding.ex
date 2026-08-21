defmodule VmuCore.CMS.DebitFunding do
  @moduledoc """
  A deposit/load transaction into a `DebitAccount` (Way4 parity plan
  Phase 1 item 4, D2). `EXTERNAL_BANK_TRANSFER`/`CASH_DEPOSIT` are
  recorded as real transactions with a channel tag + `external_reference`
  for future reconciliation, but with **no live rail call** — no
  bank-rail/cash-network integration exists anywhere in this codebase,
  confirmed before this decision. Same "data model now, real integration
  later" shape already shipped for Avenza's Prepaid `PrepaidLoad.channel`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_channels ~w[INTERNAL_TRANSFER ADMIN_MANUAL EXTERNAL_BANK_TRANSFER CASH_DEPOSIT]

  schema "cms_debit_fundings" do
    field :debit_account_id,   :binary_id
    field :amount,             :decimal
    field :channel,            :string
    field :external_reference, :string
    field :posted_by,          :string
    field :ledger_entry_id,    :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w[debit_account_id amount channel posted_by]a
  @optional ~w[external_reference ledger_entry_id]a

  def changeset(funding, attrs) do
    funding
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:channel, @valid_channels)
    |> validate_number(:amount, greater_than: 0)
    |> validate_external_reference()
    |> unique_constraint(:external_reference,
         name: :cms_debit_fundings_external_reference_index)
  end

  # External channels have no live rail integration to confirm against —
  # the reference is the only thing a future reconciliation file could
  # match on, so it's required for those channels even though the column
  # itself is nullable (internal/admin channels have nothing to reference).
  defp validate_external_reference(changeset) do
    case get_field(changeset, :channel) do
      c when c in ["EXTERNAL_BANK_TRANSFER", "CASH_DEPOSIT"] ->
        validate_required(changeset, [:external_reference])
      _ ->
        changeset
    end
  end
end
