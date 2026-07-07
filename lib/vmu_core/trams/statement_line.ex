defmodule VmuCore.TRAMS.StatementLine do
  @moduledoc """
  Transaction-level statement line (TRAM-P1 1F, spec 07 §2.3).

  The per-line feed TRAM supplies to billing — complements
  `VmuCore.CMS.StatementGenerator`, which produces the balance-level snapshot
  (statement balance, interest, minimum payment) but has no line items.

  `reference` carries the RRN — this is what the cardholder quotes back when
  disputing, so it must round-trip through statement rendering unchanged.
  The unique (transaction_id, statement_date, line_type) index makes cycle
  extraction (TRAM-P5) idempotent: re-running a cutoff can never duplicate a
  line. Late reversals/adjustments become new lines on the NEXT cycle
  (`adjustment_flag: true`), never edits to an issued statement.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @line_types ~w[PURCHASE CASH_ADV FEE ADJUSTMENT_CREDIT ADJUSTMENT_DEBIT REVERSAL]

  schema "trams_statement_lines" do
    field :transaction_id,   :binary_id
    field :account_id,       :binary_id
    field :statement_date,   :date
    field :line_type,        :string, default: "PURCHASE"
    field :transaction_date, :date
    field :posting_date,     :date
    field :merchant_name,    :string
    field :mcc,              :string
    field :amount,           :decimal
    field :currency,         :string
    field :orig_amount,      :decimal
    field :orig_currency,    :string
    field :fx_rate,          :decimal
    field :reference,        :string
    field :adjustment_flag,  :boolean, default: false

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w[transaction_id account_id statement_date line_type amount]a
  @optional ~w[transaction_date posting_date merchant_name mcc currency
               orig_amount orig_currency fx_rate reference adjustment_flag]a

  def changeset(line, attrs) do
    line
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:line_type, @line_types)
    |> unique_constraint([:transaction_id, :statement_date, :line_type])
  end
end
