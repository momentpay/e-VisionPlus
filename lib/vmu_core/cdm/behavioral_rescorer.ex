defmodule VmuCore.CDM.BehavioralRescorer do
  @moduledoc """
  Oban periodic job that re-evaluates existing accounts and adjusts credit limits
  based on 6-month behavioural signals (payment history, utilization, delinquency).

  Scheduled monthly by inserting a recurring Oban job at EOD orchestration time.
  Each account is scored independently — failures don't block others.

  Actions:
    UPGRADE   → increase limit by upgrade_step_pct (default 10%)
    DOWNGRADE → decrease limit by downgrade_step_pct (default 20%)
    SUSPEND   → set account_status = "RESTRICTED" on severe deterioration
    NO_CHANGE → no action taken
  """

  use Oban.Worker, queue: :cdm, max_attempts: 3, unique: [period: 86_400]

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.InternalGlPoster}
  alias VmuCore.Shared.{ParameterEngine, AccountStateCoordinator}
  alias Decimal, as: D

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id}}) do
    account = Repo.get!(Account, account_id)
    Logger.info("[CDM/Rescore] Evaluating account: #{account_id}")

    signals = gather_signals(account)
    action  = decide_action(signals, account)
    apply_action(action, account, signals)

    :ok
  end

  def perform(%Oban.Job{args: %{"batch" => true}}) do
    # Fan out — insert one job per ACTIVE account
    account_ids =
      Repo.all(from a in Account, where: a.account_status == "ACTIVE", select: a.account_id)

    Enum.each(account_ids, fn id ->
      Oban.insert(new(%{"account_id" => id}))
    end)

    Logger.info("[CDM/Rescore] Queued #{length(account_ids)} accounts for rescoring")
    :ok
  end

  # ---------------------------------------------------------------------------
  # Signals
  # ---------------------------------------------------------------------------

  defp gather_signals(account) do
    bucket   = Repo.get_by(BalanceBucket, account_id: account.account_id)
    utilization = if D.gt?(account.credit_limit, D.new(0)) do
      D.div(D.sub(account.credit_limit, account.open_to_buy), account.credit_limit)
    else
      D.new(0)
    end

    %{
      delinquency_bucket: account.delinquency_bucket,
      utilization:        utilization,
      months_since_dpd:   months_since_delinquency(account),
      has_disputed:       bucket && D.gt?(bucket.disputed_amount, D.new(0))
    }
  end

  defp months_since_delinquency(account) do
    case account.last_dpd_date do
      nil  -> 999
      date -> Date.diff(Date.utc_today(), date) |> div(30)
    end
  end

  # ---------------------------------------------------------------------------
  # Decision
  # ---------------------------------------------------------------------------

  defp decide_action(%{delinquency_bucket: bucket}, _account) when bucket >= 90,
    do: :suspend

  defp decide_action(%{delinquency_bucket: bucket, months_since_dpd: months}, _account)
       when bucket > 0 or months < 3,
    do: :downgrade

  defp decide_action(%{utilization: u, months_since_dpd: months}, _account) do
    cond do
      D.compare(u, D.new("0.9")) == :gt              -> :downgrade  # very high utilization
      months >= 12 and D.compare(u, D.new("0.6")) != :gt -> :upgrade
      true -> :no_change
    end
  end

  # ---------------------------------------------------------------------------
  # Actions
  # ---------------------------------------------------------------------------

  defp apply_action(:no_change, account, _signals) do
    Logger.info("[CDM/Rescore] No change — account: #{account.account_id}")
  end

  defp apply_action(:suspend, account, signals) do
    Logger.warning("[CDM/Rescore] Suspending account #{account.account_id} DPD=#{signals.delinquency_bucket}")

    Repo.update_all(
      from(a in Account, where: a.account_id == ^account.account_id),
      set: [account_status: "RESTRICTED", updated_at: NaiveDateTime.utc_now()]
    )

    AccountStateCoordinator.notify_status_change(account.account_id, "RESTRICTED")
  end

  defp apply_action(direction, account, _signals) when direction in [:upgrade, :downgrade] do
    {sys_id, bank_id, logo_id} = {account.sys_id, account.bank_id, account.logo_id}

    step_pct = case direction do
      :upgrade   -> param_decimal(sys_id, bank_id, logo_id, "cdm_upgrade_step_pct", "0.10")
      :downgrade -> param_decimal(sys_id, bank_id, logo_id, "cdm_downgrade_step_pct", "0.20")
    end

    max_limit = param_decimal(sys_id, bank_id, logo_id, "cdm_max_limit", "50000.00")
    min_limit = param_decimal(sys_id, bank_id, logo_id, "cdm_min_limit", "500.00")

    new_limit = case direction do
      :upgrade   -> D.mult(account.credit_limit, D.add(D.new(1), step_pct))
      :downgrade -> D.mult(account.credit_limit, D.sub(D.new(1), step_pct))
    end
    |> D.round(2)
    |> D.min(max_limit)
    |> D.max(min_limit)

    Logger.info("[CDM/Rescore] #{direction} account #{account.account_id}: #{account.credit_limit} → #{new_limit}")

    Repo.update_all(
      from(a in Account, where: a.account_id == ^account.account_id),
      set: [credit_limit: new_limit, updated_at: NaiveDateTime.utc_now()]
    )

    AccountStateCoordinator.refresh_limit(account.account_id, new_limit)
  end

  defp param_decimal(sys_id, bank_id, logo_id, key, default) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, nil, key) do
      {:ok, val} ->
        case D.parse(val) do
          {d, ""} -> d
          _       -> D.new(default)
        end
      _ -> D.new(default)
    end
  end
end
