defmodule VmuCore.CMS.BalanceBucket do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:bucket_id, :binary_id, autogenerate: true}

  schema "cms_balance_buckets" do
    field :account_id,       :binary_id
    field :retail_balance,   :decimal, default: Decimal.new(0)
    field :cash_balance,     :decimal, default: Decimal.new(0)
    field :bt_balance,       :decimal, default: Decimal.new(0)   # balance transfer outstanding (3C)
    field :accrued_interest, :decimal, default: Decimal.new(0)
    field :unpaid_fees,      :decimal, default: Decimal.new(0)
    field :disputed_amount,  :decimal, default: Decimal.new(0)
    field :emi_balance,      :decimal, default: Decimal.new(0)   # outstanding EMI principal
    field :statement_balance,:decimal, default: Decimal.new(0)
    field :minimum_payment,  :decimal, default: Decimal.new(0)
    field :currency,         :string, default: "AED"              # functional currency of account (4B)
    field :balance_date,     :date

    timestamps()
  end

  @required [:account_id, :balance_date]
  @optional [:retail_balance, :cash_balance, :bt_balance, :accrued_interest, :unpaid_fees,
             :disputed_amount, :emi_balance, :statement_balance, :minimum_payment, :currency]

  def changeset(bucket, attrs) do
    bucket
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> unique_constraint([:account_id, :balance_date])
  end

  @doc "Sum of all outstanding balances (principal pools + EMI + BT + interest + fees)."
  def total(%__MODULE__{} = b) do
    Decimal.add(b.retail_balance, b.cash_balance)
    |> Decimal.add(b.bt_balance      || Decimal.new(0))
    |> Decimal.add(b.emi_balance     || Decimal.new(0))
    |> Decimal.add(b.accrued_interest)
    |> Decimal.add(b.unpaid_fees)
  end
end
