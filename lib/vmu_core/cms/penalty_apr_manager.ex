defmodule VmuCore.CMS.PenaltyAprManager do
  @moduledoc """
  Penalty APR persistence + cure evaluation (CMS-G1 ADR-C2).

  ## Why this exists

  Before CMS-G1, penalty pricing was stateless: the accrual job compared
  `delinquency_bucket >= penalty_apr_dpd_trigger` each night, so the penalty
  APR silently dropped the moment arrears cleared. Per the reviewed cure
  rules, penalty pricing must **persist until the account cures**.

  ## Rule grammar (`penalty_apr_cure_rule` LOGO parameter)

  | Rule string | Meaning |
  |---|---|
  | `arrears_cleared_immediately` | Deactivate as soon as DPD = 0 |
  | `arrears_cleared_and_<N>_cycles_current` | After arrears clear, the account must remain current for N consecutive statement cycles (e.g. `arrears_cleared_and_2_cycles_current`) |

  Unknown rule strings fall back to `arrears_cleared_immediately` with a
  warning — fail-open toward the cardholder, never toward extended penalty.

  ## Lifecycle

  - **Activation** — `maybe_activate/2` from the nightly accrual job when
    DPD ≥ trigger: sets `penalty_apr_active`, resets `penalty_cure_cycles`.
  - **Persistence** — accrual prices with penalty APR while
    `penalty_apr_active` is true, regardless of current DPD.
  - **Cure** — `evaluate_cure/1` once per statement cycle (from
    `GenerateStatementJob`): DPD > 0 resets the counter; DPD = 0 increments
    it and deactivates when the rule is satisfied.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account}
  alias VmuCore.Shared.ParameterEngine

  @doc """
  Activate penalty pricing if the account isn't already penalized.
  Called from the accrual job when DPD ≥ trigger. Idempotent.
  """
  @spec maybe_activate(Account.t(), non_neg_integer()) :: :activated | :already_active
  def maybe_activate(%Account{penalty_apr_active: true}, _dpd), do: :already_active

  def maybe_activate(%Account{} = account, dpd) do
    Logger.warning("[PenaltyAPR] Activating for account #{account.account_id} DPD=#{dpd}")

    Repo.update_all(
      from(a in Account, where: a.account_id == ^account.account_id),
      set: [penalty_apr_active: true, penalty_cure_cycles: 0,
            updated_at: NaiveDateTime.utc_now()]
    )

    :activated
  end

  @doc """
  True when the account should be priced at penalty APR this accrual run —
  either persistently active, or crossing the trigger right now.
  """
  @spec penalized?(Account.t(), non_neg_integer(), non_neg_integer()) :: boolean()
  def penalized?(%Account{penalty_apr_active: true}, _dpd, _trigger), do: true
  def penalized?(_account, dpd, trigger), do: dpd >= trigger

  @doc """
  Evaluate the cure rule at statement cycle. Called once per cycle from
  `GenerateStatementJob` — no-op when penalty is not active.

  Returns `:cured` | `:progressing` (counter advanced) | `:reset`
  (arrears present, counter zeroed) | `:not_active`.
  """
  @spec evaluate_cure(Account.t()) :: :cured | :progressing | :reset | :not_active
  def evaluate_cure(%Account{penalty_apr_active: false}), do: :not_active

  def evaluate_cure(%Account{} = account) do
    dpd  = account.delinquency_bucket || 0
    rule = cure_rule(account)

    cond do
      dpd > 0 ->
        # Arrears present — cure progress resets
        set_cure_state(account, active: true, cycles: 0)
        :reset

      rule == :immediately ->
        deactivate(account)
        :cured

      true ->
        {:cycles, required} = rule
        new_cycles = (account.penalty_cure_cycles || 0) + 1

        if new_cycles >= required do
          deactivate(account)
          :cured
        else
          set_cure_state(account, active: true, cycles: new_cycles)
          Logger.info("[PenaltyAPR] Cure progressing account=#{account.account_id} " <>
                      "#{new_cycles}/#{required} current cycles")
          :progressing
        end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp cure_rule(account) do
    raw =
      case ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id,
                               account.block_id || "", :penalty_apr_cure_rule) do
        {:ok, rule} when is_binary(rule) -> rule
        _ -> "arrears_cleared_immediately"
      end

    parse_rule(raw)
  end

  defp parse_rule("arrears_cleared_immediately"), do: :immediately

  defp parse_rule(rule) do
    case Regex.run(~r/^arrears_cleared_and_(\d+)_cycles_current$/, rule) do
      [_, n] ->
        {:cycles, String.to_integer(n)}

      nil ->
        Logger.warning("[PenaltyAPR] Unknown cure rule #{inspect(rule)} — " <>
                       "falling back to arrears_cleared_immediately")
        :immediately
    end
  end

  defp deactivate(account) do
    Logger.info("[PenaltyAPR] CURED — deactivating for account #{account.account_id}")
    set_cure_state(account, active: false, cycles: 0)
  end

  defp set_cure_state(account, active: active, cycles: cycles) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^account.account_id),
      set: [penalty_apr_active: active, penalty_cure_cycles: cycles,
            updated_at: NaiveDateTime.utc_now()]
    )
  end
end
