defmodule VmuCore.CMS.ExternalPayment do
  @moduledoc """
  A wallet-out payment to an external bank account — Digital Wallet Phase
  W6 (2026-07-29), covering both A2A (W011) and Instant Payments (W012).
  Same domain shape for both; `rail_type` is the only thing that varies
  ("A2A" vs "INSTANT"), since the actual rail connectivity is pluggable
  (`CMS.RailProvider` behaviour) and still an external vendor decision
  either way.

  `destination` holds whatever the chosen rail needs to identify the
  receiving bank account (IBAN, routing/SWIFT, beneficiary name, ...) — a
  free-form map rather than fixed columns, since the required fields
  aren't the same across every candidate rail/vendor and shouldn't force
  a schema migration per provider.

  `risk_decision` freezes the `FAS.RiskAdapter.evaluate/1` result
  (decision/score/fired_rules/model_version) at initiation time — an
  audit trail of *why* this payment was allowed to proceed to the rail,
  same posture as `Kyc.Request.fields_snapshot` freezing what a customer
  was actually asked.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @rail_types ~w[A2A INSTANT]
  @statuses ~w[initiated risk_declined submitted completed failed]

  schema "cms_external_payments" do
    field :wallet_account_id,  :binary_id
    field :customer_id,        :binary_id
    field :rail_type,          :string
    field :rail_provider,      :string
    field :amount,             :decimal
    field :currency,           :string
    field :destination,        :map, default: %{}
    field :status,             :string, default: "initiated"
    field :risk_decision,      :map
    field :ledger_entry_id,    :binary_id
    field :external_reference, :string
    field :failure_reason,     :string
    field :initiated_by,       :string
    field :submitted_at,       :utc_datetime
    field :completed_at,       :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w[wallet_account_id customer_id rail_type rail_provider amount currency destination initiated_by]a
  @optional ~w[status risk_decision ledger_entry_id external_reference failure_reason submitted_at completed_at]a

  def changeset(payment, attrs) do
    payment
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:rail_type, @rail_types)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount, greater_than: 0)
  end

  def rail_types, do: @rail_types
  def statuses, do: @statuses
end
