defmodule VmuCore.CMS.PrepaidLedgerEntry do
  @moduledoc """
  One row in a prepaid account's stored-value ledger (Way4 parity plan
  Phase 1 item 5, P1). LOAD rows carry their own `remaining_amount`
  (decremented in place as consumed — same "the ledger row itself
  reflects partial consumption" shape `LMS.PointsLedger` already uses,
  not a separately mutated account balance) and `expiry_date` (per-load
  dormancy). SPEND rows record which LOAD row(s) they drew from via
  `consumed_from`, so a reversal restores exactly the right loads.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_entry_types ~w[LOAD SPEND FEE EXPIRE REFUND ADJUSTMENT]
  @valid_statuses    ~w[ACTIVE EXPIRED]
  @valid_channels    ~w[INTERNAL_TRANSFER ADMIN_MANUAL EXTERNAL_BANK_TRANSFER CASH_DEPOSIT]

  schema "cms_prepaid_ledger_entries" do
    field :prepaid_account_id, :binary_id
    field :entry_type,         :string
    field :amount,             :decimal
    field :remaining_amount,   :decimal
    field :expiry_date,        :date
    field :status,             :string, default: "ACTIVE"
    field :channel,            :string
    field :external_reference, :string
    field :consumed_from,      {:array, :map}
    field :posted_by,          :string
    field :idempotency_key,    :string
    field :posting_date,       :date

    timestamps(type: :utc_datetime, updated_at: false)
  end

  @required ~w[prepaid_account_id entry_type amount posted_by posting_date]a
  @optional ~w[remaining_amount expiry_date status channel external_reference
               consumed_from idempotency_key]a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:entry_type, @valid_entry_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:channel, @valid_channels ++ [nil])
    |> validate_number(:amount, greater_than: 0)
    |> validate_external_reference()
    |> unique_constraint(:idempotency_key)
    |> unique_constraint(:external_reference,
         name: :cms_prepaid_ledger_entries_external_reference_index)
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
