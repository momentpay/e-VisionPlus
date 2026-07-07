defmodule VmuCore.TRAMS.Transaction do
  @moduledoc """
  TRAM transaction aggregate root (TRAM-P1 1B).

  The system of record for "what happened" to a card transaction, per
  `docs/tram/TRAM_Module_Developer_Requirements.md` Section 5. One row per
  business transaction; the full lifecycle lives in `trams_transaction_events`
  (append-only) and `state` here is a projection maintained by
  `VmuCore.TRAMS.EventStore` (ADR-T1) — never write `state` directly.

  Boundaries (spec Section 2):
  - FAS owns the authorization *decision* (`fas_authorizations`) — TRAM links
    via `fas_authorization_id` (unique → idempotent feed) and never duplicates
    rc / risk score / decision_path.
  - CMS owns balances — TRAM's posting events *trigger* ledger entries but the
    ledger itself stays in `cms_ledger_entries`.
  - Merchant details are inline (ADR-T4) until a merchant master exists.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.TRAMS.StateMachine

  @primary_key {:transaction_id, :binary_id, autogenerate: true}

  @transaction_types ~w[PURCHASE CASH_ADV FEE REVERSAL ADJUSTMENT]

  schema "trams_transactions" do
    field :account_id,           :binary_id
    field :pan_token,            :string
    field :sys_id,               :string
    field :logo_id,              :string
    field :merchant_id,          :string
    field :merchant_name,        :string
    field :mcc,                  :string
    field :transaction_type,     :string, default: "PURCHASE"
    field :channel,              :string
    field :amount,               :decimal
    field :settled_amount,       :decimal
    field :currency,             :string
    field :state,                :string, default: "INITIATED"
    field :fas_authorization_id, :binary_id
    field :clearing_id,          :binary_id
    field :transaction_date,     :utc_datetime
    field :posted_at,            :utc_datetime
    field :statement_date,       :date
    field :closed_at,            :utc_datetime

    has_many :events, VmuCore.TRAMS.TransactionEvent,
      foreign_key: :transaction_id, references: :transaction_id

    has_many :identifiers, VmuCore.TRAMS.TransactionIdentifier,
      foreign_key: :transaction_id, references: :transaction_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[pan_token transaction_type amount state]a
  @optional ~w[account_id sys_id logo_id merchant_id merchant_name mcc channel
               settled_amount currency fas_authorization_id clearing_id
               transaction_date posted_at statement_date closed_at]a

  def changeset(txn, attrs) do
    txn
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:pan_token, is: 64)
    |> validate_inclusion(:transaction_type, @transaction_types)
    |> validate_inclusion(:state, StateMachine.states())
    |> unique_constraint(:fas_authorization_id)
  end
end
