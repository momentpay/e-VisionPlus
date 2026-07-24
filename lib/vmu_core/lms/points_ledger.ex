defmodule VmuCore.LMS.PointsLedger do
  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  # M2 (2026-07-17): config-injected — see vmu_shared's identical fix.
  @repo Application.compile_env(:vmu_lms, :repo, VmuCore.Repo)

  schema "lms_points_ledger" do
    field :lms_account_id,      :integer
    field :transaction_type,    :string
    field :points_amount,       :decimal
    field :monetary_equiv,      :decimal
    field :transaction_date,    :date
    field :posting_date,        :date
    field :expiry_date,         :date
    field :warehouse_state,     :string, default: "ACTIVE"
    field :plan_id,             :integer
    field :group_id,            :integer
    field :scheme_id,           :integer
    field :merchant_id,         :binary_id
    field :source_clearing_id,  :integer
    field :idempotency_key,     :string
    field :batch_date,          :date
    field :settled_at,          :utc_datetime
    field :statemented_at,      :utc_datetime
    field :inserted_at,         :utc_datetime
  end

  @valid_txn_types    ~w(BASIC_EARNED BONUS_EARNED REDEEMED ADJUSTMENT EXPIRED)
  @valid_warehouse    ~w(WAREHOUSE ACTIVE HISTORY)

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, [:lms_account_id, :transaction_type, :points_amount, :monetary_equiv,
                    :transaction_date, :posting_date, :expiry_date, :warehouse_state,
                    :plan_id, :group_id, :scheme_id, :merchant_id,
                    :source_clearing_id, :idempotency_key, :batch_date,
                    :settled_at, :statemented_at, :inserted_at])
    |> validate_required([:lms_account_id, :transaction_type, :points_amount,
                           :monetary_equiv, :transaction_date, :posting_date, :scheme_id])
    |> validate_inclusion(:transaction_type, @valid_txn_types)
    |> validate_inclusion(:warehouse_state, @valid_warehouse)
    |> unique_constraint(:idempotency_key)
  end

  @doc """
  Sum of ACTIVE-state ledger entries for an account — the authoritative
  redeemable balance (LMS-P1 fix, 2026-07-11). `points_amount` on ACTIVE rows
  already reflects any partial consumption from prior redemptions, so this
  sum is correct without needing a separate running total.
  """
  @spec active_balance(integer()) :: Decimal.t()
  def active_balance(lms_account_id) do
    from(l in __MODULE__,
      where: l.lms_account_id == ^lms_account_id and l.warehouse_state == "ACTIVE",
      select: sum(l.points_amount)
    )
    |> @repo.one()
    |> case do
      nil -> Decimal.new(0)
      sum -> sum
    end
  end
end
