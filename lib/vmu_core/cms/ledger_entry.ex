defmodule VmuCore.CMS.LedgerEntry do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:entry_id, :binary_id, autogenerate: true}

  @transaction_codes ~w[PURCHASE CASH_ADV INTEREST FEE PAYMENT REVERSAL ADJUSTMENT DISPUTE_CREDIT]

  schema "cms_ledger_entries" do
    field :account_id,       :binary_id
    field :idempotency_key,  :string
    field :transaction_code, :string
    field :dr_amount,        :decimal
    field :cr_amount,        :decimal
    field :gl_account_dr,    :string
    field :gl_account_cr,    :string
    field :currency,         :string, default: "AED"
    field :posting_date,     :date
    field :value_date,       :date
    field :narrative,        :string
    field :source_ref,       :string

    timestamps()
  end

  @required [:account_id, :idempotency_key, :transaction_code,
             :dr_amount, :cr_amount, :gl_account_dr, :gl_account_cr,
             :posting_date, :value_date]
  @optional [:currency, :narrative, :source_ref]

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:transaction_code, @transaction_codes)
    |> validate_balanced()
    |> unique_constraint(:idempotency_key)
  end

  # Double-entry invariant: dr == cr on each journal line
  defp validate_balanced(cs) do
    dr = get_field(cs, :dr_amount) || Decimal.new(0)
    cr = get_field(cs, :cr_amount) || Decimal.new(0)

    if Decimal.compare(dr, cr) == :eq do
      cs
    else
      add_error(cs, :dr_amount, "debit and credit amounts must be equal (double-entry)")
    end
  end
end
