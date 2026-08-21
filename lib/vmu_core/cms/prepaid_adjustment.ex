defmodule VmuCore.CMS.PrepaidAdjustment do
  @moduledoc """
  A manual, 4-eyes-approved correction to a Prepaid account's stored
  value — Card Products UX Parity Phase 2c (2026-07-28). Mirrors `CMS.
  DebitAdjustment`'s shape exactly (operator_id/supervisor_id as
  usernames, `operator_id != supervisor_id` enforced in this changeset).

  `direction`: CREDIT increases the balance (a new spendable ADJUSTMENT
  ledger row, same shape as a LOAD), DEBIT decreases it (consumes ACTIVE
  loads FIFO). Same polarity as Debit's own Adjustments — the opposite
  of Credit's card-side `CMS.FinancialAdjustment`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_directions ~w[CREDIT DEBIT]

  schema "cms_prepaid_adjustments" do
    field :prepaid_account_id, :binary_id
    field :direction,          :string
    field :amount,             :decimal
    field :reason,             :string
    field :reference_id,       :string
    field :operator_id,        :string
    field :supervisor_id,      :string
    field :ledger_entry_id,    :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required ~w[prepaid_account_id direction amount reason reference_id operator_id supervisor_id]a
  @optional ~w[ledger_entry_id]a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:direction, @valid_directions)
    |> validate_number(:amount, greater_than: 0)
    |> validate_length(:reason, max: 100)
    |> validate_4_eyes()
  end

  defp validate_4_eyes(cs) do
    op = get_field(cs, :operator_id)
    sup = get_field(cs, :supervisor_id)

    if op && sup && op == sup,
      do: add_error(cs, :supervisor_id, "supervisor_id must differ from operator_id (4-eyes required)"),
      else: cs
  end
end
