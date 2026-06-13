defmodule VmuCore.LMS.MerchantSettlement do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_merchant_settlement" do
    field :merchant_id,            :binary_id
    field :group_id,               :integer
    field :settlement_period_from, :date
    field :settlement_period_to,   :date
    field :total_bonus_points,     :decimal
    field :charge_rate_pct,        :decimal
    field :settlement_amount,      :decimal
    field :settlement_method,      :string    # DIRECT_DEBIT | INVOICE | BOTH
    field :status,                 :string, default: "PENDING"
    field :gl_entry_id,            :integer
    field :inserted_at,            :utc_datetime
  end

  @valid_methods  ~w(DIRECT_DEBIT INVOICE BOTH)
  @valid_statuses ~w(PENDING PROCESSED SETTLED FAILED)

  def changeset(settlement, attrs) do
    settlement
    |> cast(attrs, [:merchant_id, :group_id, :settlement_period_from, :settlement_period_to,
                    :total_bonus_points, :charge_rate_pct, :settlement_amount,
                    :settlement_method, :status, :gl_entry_id, :inserted_at])
    |> validate_required([:merchant_id, :group_id, :settlement_period_from,
                           :settlement_period_to, :total_bonus_points,
                           :charge_rate_pct, :settlement_amount, :settlement_method])
    |> validate_inclusion(:settlement_method, @valid_methods)
    |> validate_inclusion(:status, @valid_statuses)
  end
end
