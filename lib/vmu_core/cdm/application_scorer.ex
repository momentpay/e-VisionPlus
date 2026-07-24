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

  Every application — approve or decline on tier — is additionally screened
  against the sanctions list (`SanctionsScreening`) before persisting. A
  confirmed hit always overrides to DECLINED regardless of tier outcome
  (mirrors FAS's own "sanction always declines" precedent); a screening that
  could not complete overrides to REFERRED (fail-closed) rather than letting
  an unscreened application through as approved.
  """

  require Logger
  alias VmuCore.CDM.{BureauAdapter, LimitAllocator, SanctionsScreening}
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
         {:ok, tier}   <- classify_risk(bureau.score) do

      decision =
        application
        |> build_decision(tier, bureau, existing_payments)
        |> apply_sanctions_screening(customer)

      persist_decision(application_id, decision)

      Logger.info(
        "[CDM] Decision: #{decision.status} tier=#{decision.risk_tier} " <>
          "limit=#{decision.approved_limit} sanctions=#{decision.sanctions_status}"
      )

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

  # Tier/DSR outcomes are expected business results, not system failures — both
  # approval AND decline must always reach `persist_decision/2`. (Found live,
  # 2026-07-23: `LimitAllocator.calculate/6` returns `{:error, :tier_declined}`
  # / `{:error, :dsr_cap_exceeded}` for expected declines; routing those through
  # a `with`-chain short-circuit — as this function previously did — means a
  # declined application never gets persisted at all and its row is stuck at
  # `status: "PENDING"` forever. Same bug class `CDM_Gap_Implementation_Tracker.md`
  # CDM-P1 already documented as fixed; live-checking this file found the fix
  # was not actually present in the code — restored here as part of this change
  # since sanctions screening needs a single decision-building path that always
  # persists, for both approval and decline.)
  defp build_decision(application, tier, bureau, existing_payments) do
    base = %{
      risk_tier:    Atom.to_string(tier) |> String.upcase(),
      bureau_ref:   bureau.bureau_ref,
      bureau_score: bureau.score,
      decided_at:   now()
    }

    case LimitAllocator.calculate(application.monthly_income, tier, application.sys_id,
           application.bank_id, application.logo_id, existing_payments) do
      {:ok, limit} ->
        Map.merge(base, %{status: :approved, approved_limit: limit, decline_reason: nil})

      {:error, :tier_declined} ->
        Map.merge(base, %{
          status: :declined,
          approved_limit: D.new(0),
          decline_reason: "LOW_BUREAU_SCORE"
        })

      {:error, :dsr_cap_exceeded} ->
        Map.merge(base, %{
          status: :declined,
          approved_limit: D.new(0),
          decline_reason: "DSR_CAP_EXCEEDED"
        })
    end
  end

  # Screens the applicant (individual name + company name, when present) via
  # `SanctionsScreening.screen/1` and reconciles the result onto the
  # tier/DSR-based `decision` already built by `build_decision/4`:
  #   :clear         → decision unchanged, sanctions_status recorded
  #   {:hit, _}      → always overrides to DECLINED, regardless of tier result
  #                    (mirrors FAS's own "sanction always declines" rule)
  #   :error         → always overrides to REFERRED (fail-closed) — an
  #                    application must never reach APPROVED when screening
  #                    could not complete
  defp apply_sanctions_screening(decision, customer) do
    identity = %{full_name: full_name(customer), company_name: customer.company_name}
    screened_at = now()

    case SanctionsScreening.screen(identity) do
      :clear ->
        Map.merge(decision, %{
          sanctions_status: "CLEAR",
          sanctions_reference: nil,
          sanctions_screened_at: screened_at
        })

      {:hit, %{matched_name: name, list_type: list_type}} ->
        Map.merge(decision, %{
          status: :declined,
          approved_limit: D.new(0),
          decline_reason: "SANCTIONS_HIT",
          sanctions_status: "HIT",
          sanctions_reference: "#{name} (#{list_type})",
          sanctions_screened_at: screened_at
        })

      :error ->
        Map.merge(decision, %{
          status: :referred,
          decline_reason: "SANCTIONS_SCREENING_UNAVAILABLE",
          sanctions_status: "UNAVAILABLE",
          sanctions_reference: nil,
          sanctions_screened_at: nil
        })
    end
  end

  defp full_name(customer) do
    [customer.first_name, customer.last_name]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" ")
    |> case do
      "" -> nil
      name -> name
    end
  end

  defp persist_decision(application_id, decision) do
    import Ecto.Query
    status_str = decision.status |> Atom.to_string() |> String.upcase()

    Repo.update_all(
      from(a in __MODULE__.Application, where: a.application_id == ^application_id),
      set: [
        status:                status_str,
        approved_limit:        decision.approved_limit,
        bureau_score:          decision.bureau_score,
        bureau_ref:            decision.bureau_ref,
        risk_tier:             decision.risk_tier,
        decline_reason:        decision.decline_reason,
        sanctions_status:      decision.sanctions_status,
        sanctions_reference:   decision.sanctions_reference,
        sanctions_screened_at: decision.sanctions_screened_at,
        decided_at:            decision.decided_at,
        updated_at:            now()
      ]
    )
  end

  # `:naive_datetime` (non-usec) fields raise `ArgumentError` at dump time if
  # given a value with fractional seconds (`NaiveDateTime.utc_now/0` always
  # has microseconds) — found live, 2026-07-23, while verifying this change
  # against a real Postgres insert. Every `NaiveDateTime.utc_now()` written
  # into this schema needs truncation; centralized here so it can't be missed
  # on a future field addition.
  defp now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

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
      field :sanctions_status,      :string
      field :sanctions_reference,   :string
      field :sanctions_screened_at, :naive_datetime
      field :submitted_at,    :naive_datetime
      field :decided_at,      :naive_datetime

      timestamps()
    end

    @type t :: %__MODULE__{}
  end
end
