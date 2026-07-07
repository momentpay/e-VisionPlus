defmodule VmuCore.CMS.EmiSchedule do
  @moduledoc """
  EMI (Equal Monthly Instalment) schedule for credit card instalment plans.

  When a retail transaction is converted to EMI, a schedule is created with
  one row per instalment period. Each row captures:

  - The planned instalment due date
  - Principal and interest components for that instalment
  - Actual payment date (nil until paid)
  - Running outstanding balance after payment

  ## VisionPlus EMI model

  In VisionPlus, EMI is a sub-product under the PLAN segment with
  `plan_type: "EMI"`. The EMI plan has:

  - `emi_tenor_months`  — total number of instalments (3, 6, 9, 12, 18, 24, 36)
  - `apr`               — annual flat rate OR reducing balance rate
  - `payment_priority`  — which instalment bucket is paid first

  ## Flat rate vs reducing balance

  VisionPlus EMI typically uses a **flat rate** method:

      monthly_interest = (principal × flat_rate_percent × tenor_months) / tenor_months
      monthly_instalment = (principal + total_interest) / tenor_months

  This produces equal instalments for the life of the plan.

  ## Usage

      alias VmuCore.CMS.EmiSchedule

      {:ok, schedules} = EmiSchedule.create_schedule(
        account_id:     acc.account_id,
        plan_id:        "EMI12",
        transaction_id: txn_id,
        principal:      Decimal.new("6000.00"),
        tenor_months:   12,
        flat_rate_pct:  Decimal.new("1.5"),    # 1.5% per month flat
        first_due_date: ~D[2026-07-15]
      )
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo
  alias Decimal, as: D

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_statuses ~w[PENDING PAID OVERDUE WAIVED]

  schema "cms_emi_schedules" do
    field :account_id,     :binary_id
    field :plan_id,        :string
    field :transaction_id, :binary_id          # originating purchase that was EMI-converted
    field :instalment_no,  :integer            # 1-based (1 of 12, 2 of 12 …)
    field :tenor_total,    :integer            # total number of instalments
    field :due_date,       :date
    field :principal_due,  :decimal
    field :interest_due,   :decimal
    field :instalment_due, :decimal            # principal_due + interest_due
    field :paid_date,      :date
    field :paid_amount,    :decimal
    field :outstanding,    :decimal            # remaining principal after this instalment
    field :status,         :string, default: "PENDING"

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required [:account_id, :plan_id, :instalment_no, :tenor_total,
             :due_date, :principal_due, :interest_due, :instalment_due, :outstanding]
  @optional [:transaction_id, :paid_date, :paid_amount, :status]

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:instalment_no, greater_than: 0)
    |> validate_number(:tenor_total,   greater_than: 0)
    |> validate_number(:principal_due, greater_than_or_equal_to: 0)
    |> validate_number(:interest_due,  greater_than_or_equal_to: 0)
    |> validate_number(:instalment_due, greater_than: 0)
    |> validate_number(:outstanding,   greater_than_or_equal_to: 0)
  end

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Generate and persist an EMI schedule using the flat-rate method.

  ## Options (keyword list)

    - `:account_id`     — (required) account UUID
    - `:plan_id`        — (required) plan identifier (from plan_segments)
    - `:principal`      — (required) Decimal — original transaction amount
    - `:tenor_months`   — (required) integer — number of monthly instalments
    - `:flat_rate_pct`  — (required) Decimal — monthly flat rate % (e.g. `Decimal.new("1.5")`)
    - `:first_due_date` — (required) `Date.t()` — due date of instalment 1
    - `:transaction_id` — (optional) originating transaction UUID

  Returns `{:ok, [%EmiSchedule{}, ...]}` with one entry per instalment.
  """
  @spec create_schedule(keyword()) :: {:ok, [__MODULE__.t()]} | {:error, term()}
  def create_schedule(opts) do
    account_id     = Keyword.fetch!(opts, :account_id)
    plan_id        = Keyword.fetch!(opts, :plan_id)
    principal      = Keyword.fetch!(opts, :principal)
    tenor          = Keyword.fetch!(opts, :tenor_months)
    flat_rate_pct  = Keyword.fetch!(opts, :flat_rate_pct)
    first_due_date = Keyword.fetch!(opts, :first_due_date)
    transaction_id = Keyword.get(opts, :transaction_id)

    tenor_d    = D.new(tenor)
    rate       = D.div(flat_rate_pct, D.new(100))

    # Flat rate: total interest = principal × rate × tenor
    total_interest     = D.mult(D.mult(principal, rate), tenor_d) |> D.round(2, :ceiling)
    monthly_interest   = D.div(total_interest, tenor_d) |> D.round(2)
    monthly_principal  = D.div(principal, tenor_d) |> D.round(2)
    monthly_instalment = D.add(monthly_principal, monthly_interest)

    Repo.transaction(fn ->
      {schedules, _remaining} =
        Enum.reduce(1..tenor, {[], principal}, fn i, {acc, remaining_principal} ->
          due_date = add_months(first_due_date, i - 1)

          # Last instalment: pay whatever is left to avoid rounding drift
          {inst_principal, new_outstanding} =
            if i == tenor do
              {remaining_principal, D.new(0)}
            else
              new_remaining = D.sub(remaining_principal, monthly_principal)
              {monthly_principal, new_remaining}
            end

          attrs = %{
            account_id:     account_id,
            plan_id:        plan_id,
            transaction_id: transaction_id,
            instalment_no:  i,
            tenor_total:    tenor,
            due_date:       due_date,
            principal_due:  inst_principal,
            interest_due:   monthly_interest,
            instalment_due: D.add(inst_principal, monthly_interest),
            outstanding:    new_outstanding,
            status:         "PENDING"
          }

          case Repo.insert(%__MODULE__{} |> changeset(attrs)) do
            {:ok, sched}  -> {[sched | acc], new_outstanding}
            {:error, cs}  -> Repo.rollback(cs)
          end
        end)

      Enum.reverse(schedules)
    end)
  end

  @doc """
  List all EMI schedule rows for an account, ordered by due date.
  """
  @spec list_for(binary()) :: [__MODULE__.t()]
  def list_for(account_id) do
    Repo.all(
      from s in __MODULE__,
        where: s.account_id == ^account_id,
        order_by: [asc: s.due_date]
    )
  end

  @doc """
  List PENDING instalments due on or before `as_of_date`. Used by EOD billing.
  """
  @spec due_on_or_before(binary(), Date.t()) :: [__MODULE__.t()]
  def due_on_or_before(account_id, as_of_date) do
    Repo.all(
      from s in __MODULE__,
        where: s.account_id == ^account_id
          and  s.due_date   <= ^as_of_date
          and  s.status     == "PENDING",
        order_by: [asc: s.due_date]
    )
  end

  @doc """
  Mark an instalment as paid.
  """
  @spec mark_paid(binary(), Date.t(), Decimal.t()) :: {:ok, __MODULE__.t()} | {:error, term()}
  def mark_paid(id, paid_date, paid_amount) do
    case Repo.get(__MODULE__, id) do
      nil     -> {:error, :not_found}
      sched   ->
        sched
        |> changeset(%{status: "PAID", paid_date: paid_date, paid_amount: paid_amount})
        |> Repo.update()
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  # Add `months` calendar months to a date, clamping to end-of-month.
  defp add_months(%Date{year: y, month: m, day: d}, months) do
    total_m = m + months
    {new_y, new_m} = {y + div(total_m - 1, 12), rem(total_m - 1, 12) + 1}
    max_day = Date.days_in_month(Date.new!(new_y, new_m, 1))
    Date.new!(new_y, new_m, min(d, max_day))
  end
end
