defmodule VmuCore.CMS.PlanSegment do
  @moduledoc """
  VisionPlus PLAN Segment — a sub-product within a LOGO.

  ## Plan Types

  | Type             | Grace Period | Interest | Notes                            |
  |-----------------|:------------:|:--------:|----------------------------------|
  | RETAIL          | ✓            | ADB      | Standard purchase plan           |
  | CASH            | ✗            | ADB      | Higher APR; accrues immediately  |
  | EMI             | ✗            | Fixed    | Equal monthly instalments        |
  | BALANCE_TRANSFER| ✓ (promo)    | Promo    | Typically 0% for intro period    |

  ## Payment Priority (VisionPlus standard)

    1 — Fees (always paid first)
    2 — Interest
    3 — Cash advance balance
    4 — Retail purchase balance
    5 — EMI balance

  ## Usage

  Transactions posted to an account carry a `plan_id` that routes billing and
  interest calculation to the correct plan engine. When a LOGO is set up, at
  minimum a RETAIL and CASH plan must exist.

  ## APR Resolution

  `effective_apr/1` returns the currently active rate:
    - If `promo_apr` is set and `promo_expiry_date` is in the future → promo_apr
    - Otherwise → apr
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:plan_id, :string, autogenerate: false}

  @plan_types ~w[RETAIL CASH EMI BALANCE_TRANSFER]

  schema "plan_segments" do
    field :logo_id,           :string
    field :sys_id,            :string
    field :bank_id,           :string
    field :plan_type,         :string
    field :apr,               :decimal, default: Decimal.new(0)
    field :promo_apr,         :decimal
    field :promo_expiry_date, :date
    field :grace_eligible,    :boolean, default: false
    field :min_payment_pct,   :decimal
    field :payment_priority,  :integer, default: 4
    field :statement_order,   :integer, default: 1
    field :emi_tenor_months,  :integer
    field :active,            :boolean, default: true
    field :description,       :string

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required [:plan_id, :logo_id, :sys_id, :bank_id, :plan_type, :apr, :payment_priority]
  @optional [
    :promo_apr, :promo_expiry_date, :grace_eligible, :min_payment_pct,
    :statement_order, :emi_tenor_months, :active, :description
  ]

  def changeset(plan, attrs) do
    plan
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:plan_id,  max: 8)
    |> validate_length(:logo_id,  is: 4)
    |> validate_length(:sys_id,   is: 4)
    |> validate_length(:bank_id,  is: 4)
    |> validate_inclusion(:plan_type, @plan_types)
    |> validate_number(:apr,              greater_than_or_equal_to: 0)
    |> validate_number(:payment_priority, greater_than_or_equal_to: 1, less_than_or_equal_to: 99)
    |> validate_number(:emi_tenor_months, greater_than: 0, less_than_or_equal_to: 360)
    |> validate_promo_consistency()
  end

  @doc """
  Returns the APR currently in effect for interest calculation.

  If a promotional APR is configured and not yet expired, returns `promo_apr`.
  Otherwise returns the standard `apr`.

  ## Examples

      iex> PlanSegment.effective_apr(%PlanSegment{apr: Decimal.new("24.0"), promo_apr: Decimal.new("0"), promo_expiry_date: ~D[2026-12-31]})
      Decimal.new("0")

      iex> PlanSegment.effective_apr(%PlanSegment{apr: Decimal.new("24.0"), promo_apr: nil})
      Decimal.new("24.0")
  """
  @spec effective_apr(t()) :: Decimal.t()
  def effective_apr(%__MODULE__{promo_apr: promo, promo_expiry_date: expiry, apr: apr})
      when not is_nil(promo) and not is_nil(expiry) do
    if Date.compare(Date.utc_today(), expiry) in [:lt, :eq], do: promo, else: apr
  end

  def effective_apr(%__MODULE__{apr: apr}), do: apr

  @doc """
  Returns true if this plan charges interest from the transaction date regardless
  of full payment (cash advances, EMI, balance transfers past promo period).
  """
  @spec always_accrues?(t()) :: boolean()
  def always_accrues?(%__MODULE__{plan_type: type}) when type in ["CASH", "EMI"], do: true
  def always_accrues?(%__MODULE__{grace_eligible: false}), do: true
  def always_accrues?(_), do: false

  # ── Private Helpers ────────────────────────────────────────────────────────

  defp validate_promo_consistency(changeset) do
    promo     = get_field(changeset, :promo_apr)
    expiry    = get_field(changeset, :promo_expiry_date)

    cond do
      not is_nil(promo) and is_nil(expiry) ->
        add_error(changeset, :promo_expiry_date, "required when promo_apr is set")

      is_nil(promo) and not is_nil(expiry) ->
        add_error(changeset, :promo_apr, "required when promo_expiry_date is set")

      true ->
        changeset
    end
  end
end
