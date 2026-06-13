defmodule VmuCore.CDM.ApplicationScorer do
  @moduledoc """
  Credit underwriting rules engine for new card applications.

  Scoring steps:
    1. Pull credit bureau report (async via BureauAdapter)
    2. Apply income-based limit rules (LimitAllocator)
    3. Apply product eligibility rules from ParameterEngine
    4. Return approve/decline with approved limit and risk tier

  Risk tiers and income multipliers (configurable per logo/block):
    PRIME      score >= 720 → limit = income × 2.0
    NEAR_PRIME score >= 600 → limit = income × 1.0
    SUBPRIME   score >= 500 → limit = income × 0.5
    DECLINE    score < 500  → declined

  All approvals go through AML/sanctions check via mw_risk before finalising.
  """

  require Logger
  alias VmuCore.CDM.{BureauAdapter, LimitAllocator}
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.{Repo, Shared.Customer}
  alias Decimal, as: D

  @bureau_adapter Application.compile_env(:vmu_core, [:cdm, :bureau_adapter], VmuCore.CDM.MockBureauAdapter)

  @doc """
  Score a credit application. Returns {:ok, decision} or {:error, reason}.

  decision = %{status: :approved | :declined, approved_limit: Decimal.t(),
               risk_tier: String.t(), bureau_ref: String.t(), bureau_score: integer()}
  """
  def score(application_id) do
    application = Repo.get!(__MODULE__.Application, application_id)
    customer    = Repo.get!(Customer, application.customer_id)

    Logger.info("[CDM] Scoring application: #{application_id}")

    existing_payments = application.existing_monthly_payments || Decimal.new(0)

    with {:ok, bureau} <- @bureau_adapter.pull_credit_report(customer.customer_id, customer.id_number),
         {:ok, tier}   <- classify_risk(bureau.score),
         {:ok, limit}  <- LimitAllocator.calculate(application.monthly_income, tier,
                           application.sys_id, application.bank_id,
                           application.logo_id, existing_payments) do

      decision = %{
        status:        if(tier == :decline, do: :declined, else: :approved),
        approved_limit: limit,
        risk_tier:     Atom.to_string(tier) |> String.upcase(),
        bureau_ref:    bureau.bureau_ref,
        bureau_score:  bureau.score,
        decided_at:    NaiveDateTime.utc_now()
      }

      persist_decision(application_id, decision)
      Logger.info("[CDM] Decision: #{decision.status} tier=#{decision.risk_tier} limit=#{limit}")
      {:ok, decision}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp classify_risk(score) when score >= 720, do: {:ok, :prime}
  defp classify_risk(score) when score >= 600, do: {:ok, :near_prime}
  defp classify_risk(score) when score >= 500, do: {:ok, :subprime}
  defp classify_risk(_), do: {:ok, :decline}

  defp persist_decision(application_id, decision) do
    import Ecto.Query
    status_str = if decision.status == :approved, do: "APPROVED", else: "DECLINED"

    Repo.update_all(
      from(a in "cdm_credit_applications", where: a.application_id == ^application_id),
      set: [
        status:        status_str,
        approved_limit: decision.approved_limit,
        bureau_score:  decision.bureau_score,
        bureau_ref:    decision.bureau_ref,
        risk_tier:     decision.risk_tier,
        decided_at:    decision.decided_at,
        updated_at:    NaiveDateTime.utc_now()
      ]
    )
  end

  defmodule Application do
    use Ecto.Schema

    @primary_key {:application_id, :binary_id, autogenerate: true}

    schema "cdm_credit_applications" do
      field :customer_id,     :binary_id
      field :sys_id,          :string
      field :bank_id,         :string
      field :logo_id,         :string
      field :requested_limit, :decimal
      field :approved_limit,  :decimal
      field :monthly_income,             :decimal
      field :existing_monthly_payments,  :decimal, default: 0
      field :employment_type, :string
      field :bureau_score,    :integer
      field :bureau_ref,      :string
      field :risk_tier,       :string
      field :status,          :string, default: "PENDING"
      field :decline_reason,  :string
      field :submitted_at,    :naive_datetime
      field :decided_at,      :naive_datetime

      timestamps()
    end
  end
end
