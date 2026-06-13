defmodule VmuCore.CMS.Account do
  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.CMS.BalanceBucket

  @primary_key {:account_id, :binary_id, autogenerate: true}

  schema "cms_accounts" do
    field :customer_id,        :binary_id
    field :sys_id,             :string
    field :bank_id,            :string
    field :logo_id,            :string
    field :block_id,           :string
    field :pan_token,          :string
    field :last_four,          :string
    field :expiry_date,        :string
    field :credit_limit,       :decimal
    field :open_to_buy,        :decimal
    field :cycle_code,         :integer, default: 1
    field :account_status,     :string,  default: "ACTIVE"
    field :delinquency_bucket, :integer, default: 0
    field :velocity_limits,    :map,     default: %{}
    field :campaign_code,      :string
    field :open_date,          :date
    field :close_date,         :date
    field :next_statement_date,:date
    field :last_payment_date,  :date

    has_one :balance_bucket, BalanceBucket, foreign_key: :account_id

    timestamps()
  end

  @valid_statuses ~w[ACTIVE CLOSED SUSPENDED BLOCKED DELINQUENT]

  @required [:customer_id, :sys_id, :bank_id, :logo_id, :block_id,
             :pan_token, :last_four, :expiry_date, :credit_limit]
  @optional [:open_to_buy, :cycle_code, :account_status, :delinquency_bucket,
             :velocity_limits, :campaign_code, :open_date, :close_date,
             :next_statement_date, :last_payment_date]

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:account_status, @valid_statuses)
    |> unique_constraint(:pan_token)
  end

  @doc "Returns total outstanding balance across all buckets."
  def total_balance(%__MODULE__{balance_bucket: %BalanceBucket{} = b}), do: BalanceBucket.total(b)
  def total_balance(%__MODULE__{}), do: Decimal.new(0)
end
