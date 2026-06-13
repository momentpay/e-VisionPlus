defmodule VmuCore.LMS.Account do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_accounts" do
    field :lms_account_no,    :string
    field :ar_account_id,     :binary_id
    field :scheme_id,         :integer
    field :enrollment_date,   :date
    field :enrollment_method, :string    # AUTO | MANUAL
    field :points_balance,    :decimal, default: Decimal.new(0)
    field :open_to_redeem,    :decimal, default: Decimal.new(0)
    field :lifetime_earned,   :decimal, default: Decimal.new(0)
    field :lifetime_redeemed, :decimal, default: Decimal.new(0)
    field :status,            :string, default: "ACTIVE"

    belongs_to :scheme, VmuCore.LMS.Scheme, define_field: false

    timestamps(type: :utc_datetime)
  end

  @valid_methods  ~w(AUTO MANUAL)
  @valid_statuses ~w(ACTIVE BLOCKED DELINQUENT CLOSED)

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:lms_account_no, :ar_account_id, :scheme_id,
                    :enrollment_date, :enrollment_method, :status,
                    :points_balance, :open_to_redeem, :lifetime_earned, :lifetime_redeemed])
    |> validate_required([:lms_account_no, :ar_account_id, :scheme_id,
                           :enrollment_date, :enrollment_method])
    |> validate_inclusion(:enrollment_method, @valid_methods)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:lms_account_no)
    |> unique_constraint([:ar_account_id, :scheme_id])
  end
end
