defmodule VmuCore.CMS.DebitAdjustment do
  @moduledoc """
  A manual, 4-eyes-approved correction to a Debit account's balance —
  Card Products UX Parity Phase 1c (2026-07-28). Mirrors `CMS.
  TempLimit`'s 4-eyes shape (operator_id/supervisor_id as usernames,
  `operator_id != supervisor_id` enforced in this changeset).

  `direction` uses real banking terminology for a deposit/asset account —
  the opposite polarity from Credit's card-side `CMS.FinancialAdjustment`
  (where CREDIT reduces the cardholder's owed balance): here, CREDIT
  increases `available_balance` (e.g. correcting an under-funding or
  posting a goodwill credit), DEBIT decreases it (e.g. reversing an
  over-funding).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_directions ~w[CREDIT DEBIT]

  schema "cms_debit_adjustments" do
    field :debit_account_id, :binary_id
    field :direction,        :string
    field :amount,           :decimal
    field :reason,           :string
    field :reference_id,     :string
    field :operator_id,      :string
    field :supervisor_id,    :string
    field :ledger_entry_id,  :binary_id

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required ~w[debit_account_id direction amount reason reference_id operator_id supervisor_id]a
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
