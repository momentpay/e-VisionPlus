defmodule VmuCore.COL.WorkoutCommand do
  @moduledoc """
  Maker-checker command for hardship/workout plans (COL-P9, FR-COL-014).

  `request/4` parks a plan for approval; `approve/2` gates on the approver's
  ASM role being in `col.workout_approval_matrix` for the account's bank (ADMIN
  always qualifies), then activates it.

  ## Real vs. tracked-only (honest split)

  - **`PAYMENT_HOLIDAY`** — real: `active_holiday?/2` is checked by
    `CMS.EOD.AgeBucketsJob` to suppress late/overlimit fee assessment and DPD
    aging while the holiday is active.
  - **`APR_REDUCTION`** — real: `active_apr_override/2` is checked by
    `CMS.EOD.AccrueInterestJob` (takes priority over penalty APR escalation —
    the whole point of a workout is hardship relief, so a negotiated rate
    should win over a penalty rate).
  - **`RESTRUCTURE`** — **tracked only, not wired**. `CMS.EmiSchedule.create_schedule/1`
    is the real primitive that *would* convert the outstanding balance into an
    EMI schedule, but doing so correctly needs a registered `plan_segments`
    `plan_id` for the resulting EMI plan — that's bank/logo product
    configuration, out of scope for COL to fabricate on the fly. `approve/2`
    still activates the plan record (for tracking/reporting) but logs a clear
    warning that no EMI schedule was generated; ops must set one up manually
    today.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.COL.WorkoutPlan
  alias VmuCore.Shared.ModuleConfigEngine

  # M2 (2026-07-17): config-injected — see settlement_command.ex's identical fix.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)

  @doc """
  Request a workout plan. `params` (map) required keys depend on `plan_type`:
    - `"APR_REDUCTION"` — `:new_apr` (Decimal), `:end_date` (Date)
    - `"PAYMENT_HOLIDAY"` — `:holiday_months` (integer)
    - `"RESTRUCTURE"` — `:emi_tenor_months` (integer), optional `:new_apr`
  """
  @spec request(Ecto.UUID.t(), Ecto.UUID.t(), String.t(), map()) ::
          {:ok, WorkoutPlan.t()} | {:error, term()}
  def request(case_id, account_id, plan_type, params) do
    start_date = Map.get(params, :start_date, Date.utc_today())

    end_date =
      case plan_type do
        "PAYMENT_HOLIDAY" -> Date.add(start_date, Map.fetch!(params, :holiday_months) * 30)
        "RESTRUCTURE" -> Date.add(start_date, Map.fetch!(params, :emi_tenor_months) * 30)
        "APR_REDUCTION" -> Map.fetch!(params, :end_date)
      end

    attrs = %{
      case_id: case_id,
      account_id: account_id,
      plan_type: plan_type,
      new_apr: Map.get(params, :new_apr),
      holiday_months: Map.get(params, :holiday_months),
      emi_tenor_months: Map.get(params, :emi_tenor_months),
      start_date: start_date,
      end_date: end_date,
      reason: Map.get(params, :reason),
      requested_by: Map.fetch!(params, :requested_by)
    }

    @repo.insert(WorkoutPlan.changeset(%WorkoutPlan{}, attrs))
  end

  @doc "Approve a PENDING_APPROVAL workout plan."
  @spec approve(Ecto.UUID.t(), term()) :: {:ok, WorkoutPlan.t()} | {:error, term()}
  def approve(plan_id, %{username: _} = approver) do
    with %WorkoutPlan{} = plan <- @repo.get(WorkoutPlan, plan_id) || {:error, :not_found},
         :ok <- check_pending(plan),
         :ok <- check_maker_checker(plan, approver),
         :ok <- check_role_authorized(plan, approver) do
      if plan.plan_type == "RESTRUCTURE" do
        Logger.warning("[COL] Workout plan #{plan.id} approved as RESTRUCTURE — " <>
                        "no EMI schedule generated automatically (see WorkoutCommand moduledoc); " <>
                        "ops must set up the EMI plan manually")
      end

      plan
      |> WorkoutPlan.changeset(%{status: "ACTIVE", approved_by: approver.username})
      |> @repo.update()
    end
  end

  @doc "Reject a PENDING_APPROVAL workout plan."
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, WorkoutPlan.t()} | {:error, term()}
  def reject(plan_id, rejected_by) do
    with %WorkoutPlan{} = plan <- @repo.get(WorkoutPlan, plan_id) || {:error, :not_found},
         :ok <- check_pending(plan) do
      plan |> WorkoutPlan.changeset(%{status: "REJECTED", approved_by: rejected_by}) |> @repo.update()
    end
  end

  @doc "Pending workout plans for the approval inbox."
  @spec pending(non_neg_integer()) :: [WorkoutPlan.t()]
  def pending(limit \\ 50) do
    @repo.all(from p in WorkoutPlan, where: p.status == "PENDING_APPROVAL", order_by: [asc: p.inserted_at], limit: ^limit)
  end

  @doc "Is there an ACTIVE payment holiday covering `date` for this account?"
  @spec active_holiday?(Ecto.UUID.t(), Date.t()) :: boolean()
  def active_holiday?(account_id, date) do
    @repo.exists?(
      from p in WorkoutPlan,
        where: p.account_id == ^account_id and p.plan_type == "PAYMENT_HOLIDAY" and p.status == "ACTIVE"
           and p.start_date <= ^date and p.end_date >= ^date
    )
  end

  @doc "The negotiated APR override active for `date`, if any."
  @spec active_apr_override(Ecto.UUID.t(), Date.t()) :: {:ok, Decimal.t()} | :none
  def active_apr_override(account_id, date) do
    plan =
      @repo.one(
        from p in WorkoutPlan,
          where: p.account_id == ^account_id and p.plan_type == "APR_REDUCTION" and p.status == "ACTIVE"
             and p.start_date <= ^date and p.end_date >= ^date,
          order_by: [desc: p.inserted_at],
          limit: 1
      )

    case plan do
      %WorkoutPlan{new_apr: apr} when not is_nil(apr) -> {:ok, apr}
      _ -> :none
    end
  end

  @doc "Roles currently authorized to approve workout plans for this account's bank."
  @spec allowed_roles(term()) :: [String.t()]
  def allowed_roles(%{sys_id: sys_id, bank_id: bank_id}) do
    case ModuleConfigEngine.get("col", "workout_approval_matrix", sys_id, bank_id) do
      {:ok, roles} -> roles
      {:error, _} -> []
    end
  end

  defp check_pending(%WorkoutPlan{status: "PENDING_APPROVAL"}), do: :ok
  defp check_pending(%WorkoutPlan{status: status}), do: {:error, {:not_pending, status}}

  defp check_maker_checker(%WorkoutPlan{requested_by: maker}, %{username: checker}) when maker == checker,
    do: {:error, :maker_cannot_approve}

  defp check_maker_checker(_, _), do: :ok

  defp check_role_authorized(_plan, %{role: "ADMIN"}), do: :ok

  defp check_role_authorized(plan, %{role: role}) do
    account = @repo.get!(@account_schema, plan.account_id)

    if role in allowed_roles(account) do
      :ok
    else
      {:error, {:role_not_authorized, allowed_roles(account)}}
    end
  end
end
