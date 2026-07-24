defmodule VmuCore.CMS.CycleResegmentation do
  @moduledoc """
  Cycle resegmentation batch (CMS FR-058) — rebalances the distribution of
  accounts across billing `cycle_code`s so no single day is overloaded,
  and lets ops move an individual account's billing date.

  Every policy lever is bank-configurable (`VmuCore.CMS.ConfigCatalog`),
  not hardcoded — region/regulatory notice-period and billing-date rules
  genuinely differ by market:

    - `resegmentation_mode` — "manual" (ops applies) or "auto" (EOD applies)
    - `resegmentation_notice_days` — advance notice before a change takes effect
    - `resegmentation_min_interval_months` — cooldown between changes per account
    - `resegmentation_rebalance_threshold_pct` — how imbalanced before flagging
    - `allowed_cycle_codes` — which billing days this bank permits
    - `resegmentation_proration_method` — captured for audit at schedule time

  A resegmentation is **never applied instantly** — `schedule_resegmentation/3`
  only sets `pending_cycle_code`/`cycle_change_effective_date` on the
  account; `apply_due_changes/1` (called daily from
  `VmuCore.CMS.EOD.ApplyCycleResegmentationJob`, wired into the same
  always-runs-daily slot as `ReinstateLimitJob`) is what actually flips
  `cycle_code` once the configured notice period has elapsed.

  ## Explicit scope limitation (flagged, not silently missing)

  `resegmentation_proration_method` is captured and persisted per the
  config in effect at schedule time, but **`AccrueInterestJob`'s day-count
  math does not yet consume it** — the interest engine computes
  `days_in_cycle` purely from the account's *current* `cycle_code` and
  today's date, with no awareness that the immediately-preceding cycle
  spanned a resegmentation boundary and may have been genuinely shorter or
  longer than a normal cycle. Wiring that correctly means auditing live
  interest-calculation math for every account, not just resegmented ones —
  a distinct, higher-risk change deliberately not bundled into this pass.
  """

  import Ecto.Query
  require Logger

  alias VmuCore.{Repo, CMS.Account}
  alias VmuCore.Shared.ModuleConfigEngine
  alias VmuCore.ASM.AuditLog

  @default_allowed_codes Enum.to_list(1..31)
  @active_statuses ["ACTIVE", "DELINQUENT"]

  # ---------------------------------------------------------------------------
  # Analysis (read-only)
  # ---------------------------------------------------------------------------

  @doc """
  Current cycle_code distribution for a bank/logo scope, among active
  accounts. Read-only.
  """
  @spec analyze_distribution(String.t(), String.t(), String.t()) :: %{
          distribution: %{integer() => integer()},
          total_accounts: integer(),
          average_per_code: float(),
          threshold_pct: integer(),
          allowed_codes: [integer()]
        }
  def analyze_distribution(sys_id, bank_id, logo_id) do
    counts =
      Repo.all(
        from a in Account,
          where:
            a.sys_id == ^sys_id and a.bank_id == ^bank_id and a.logo_id == ^logo_id and
              a.account_status in ^@active_statuses,
          group_by: a.cycle_code,
          select: {a.cycle_code, count(a.account_id)}
      )
      |> Map.new()

    total = counts |> Map.values() |> Enum.sum()
    allowed_codes = allowed_codes(sys_id, bank_id, logo_id)
    {:ok, threshold_pct} = ModuleConfigEngine.get("cms", "resegmentation_rebalance_threshold_pct", sys_id, bank_id, logo_id)

    average = if allowed_codes == [], do: 0.0, else: total / length(allowed_codes)

    %{
      distribution: counts,
      total_accounts: total,
      average_per_code: average,
      threshold_pct: threshold_pct,
      allowed_codes: allowed_codes
    }
  end

  @doc """
  Propose a rebalance for a bank/logo scope. Returns `{:ok, %{status:
  :balanced | :imbalanced | :no_accounts, ...}}` — never mutates data.
  `:imbalanced` includes a `moves` list of `%{account_id:, from_cycle_code:,
  to_cycle_code:}`, restricted to accounts eligible right now (no pending
  change already, past their configured cooldown).
  """
  @spec propose_rebalance(String.t(), String.t(), String.t()) :: {:ok, map()}
  def propose_rebalance(sys_id, bank_id, logo_id) do
    analysis = analyze_distribution(sys_id, bank_id, logo_id)

    cond do
      analysis.total_accounts == 0 ->
        {:ok, Map.put(analysis, :status, :no_accounts) |> Map.put(:moves, [])}

      not imbalanced?(analysis) ->
        {:ok, Map.put(analysis, :status, :balanced) |> Map.put(:moves, [])}

      true ->
        moves = compute_moves(sys_id, bank_id, logo_id, analysis)
        {:ok, analysis |> Map.put(:status, :imbalanced) |> Map.put(:moves, moves)}
    end
  end

  defp imbalanced?(%{distribution: dist, average_per_code: avg, threshold_pct: pct, allowed_codes: allowed}) do
    max_allowed = avg * (1 + pct / 100)

    Enum.any?(dist, fn {code, n} -> code not in allowed or n > max_allowed end)
  end

  defp compute_moves(sys_id, bank_id, logo_id, %{distribution: dist, average_per_code: avg, allowed_codes: allowed}) do
    source_codes = dist |> Map.keys() |> Enum.filter(fn code -> code not in allowed or Map.get(dist, code, 0) > avg end)

    target_queue =
      allowed
      |> Enum.map(fn code -> {code, Map.get(dist, code, 0)} end)
      |> Enum.filter(fn {_code, n} -> n < avg end)
      |> Enum.sort_by(fn {_code, n} -> n end)
      |> Enum.flat_map(fn {code, n} -> List.duplicate(code, max(round(avg - n), 0)) end)

    if source_codes == [] or target_queue == [] do
      []
    else
      cutoff = interval_cutoff(sys_id, bank_id, logo_id)

      eligible =
        Repo.all(
          from a in Account,
            where:
              a.sys_id == ^sys_id and a.bank_id == ^bank_id and a.logo_id == ^logo_id and
                a.account_status in ^@active_statuses and a.cycle_code in ^source_codes and
                is_nil(a.pending_cycle_code) and
                (is_nil(a.cycle_code_changed_at) or a.cycle_code_changed_at < ^cutoff),
            order_by: [asc: a.account_id],
            select: %{account_id: a.account_id, cycle_code: a.cycle_code}
        )

      eligible
      |> Enum.zip(target_queue)
      |> Enum.map(fn {%{account_id: id, cycle_code: from}, to} ->
        %{account_id: id, from_cycle_code: from, to_cycle_code: to}
      end)
    end
  end

  # ---------------------------------------------------------------------------
  # Scheduling (mutates — sets pending fields only, never cycle_code directly)
  # ---------------------------------------------------------------------------

  @doc """
  Schedule a cycle_code change for one account, effective
  `resegmentation_notice_days` from today. Returns `{:ok, effective_date}`
  or `{:error, reason}` — `:cycle_code_not_allowed`, `:already_pending`,
  `:too_soon_since_last_change`, `:same_cycle_code`, or `:not_found`.
  """
  @spec schedule_resegmentation(Ecto.UUID.t(), integer(), VmuCore.ASM.Operator.t() | nil) ::
          {:ok, Date.t()} | {:error, atom()}
  def schedule_resegmentation(account_id, new_cycle_code, operator) do
    with %Account{} = account <- Repo.get(Account, account_id) || {:error, :not_found},
         :ok <- validate_different(account, new_cycle_code),
         :ok <- validate_not_pending(account),
         :ok <- validate_allowed(account, new_cycle_code),
         :ok <- validate_interval(account) do
      {:ok, notice_days} =
        ModuleConfigEngine.get("cms", "resegmentation_notice_days", account.sys_id, account.bank_id, account.logo_id)

      {:ok, proration} =
        ModuleConfigEngine.get("cms", "resegmentation_proration_method", account.sys_id, account.bank_id, account.logo_id)

      effective_date = Date.add(Date.utc_today(), notice_days)

      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [
          pending_cycle_code: new_cycle_code,
          cycle_change_effective_date: effective_date,
          cycle_change_proration_method: proration
        ]
      )

      AuditLog.record(operator, "cms_cycle_resegmentation_scheduled", account_id, %{
        from_cycle_code: account.cycle_code,
        to_cycle_code: new_cycle_code,
        effective_date: Date.to_iso8601(effective_date),
        proration_method: proration
      })

      {:ok, effective_date}
    end
  end

  @doc "Cancel a not-yet-effective pending change. Returns :ok or {:error, reason}."
  @spec cancel_pending(Ecto.UUID.t(), VmuCore.ASM.Operator.t() | nil) ::
          :ok | {:error, :not_found | :no_pending_change}
  def cancel_pending(account_id, operator) do
    case Repo.get(Account, account_id) do
      nil ->
        {:error, :not_found}

      %Account{pending_cycle_code: nil} ->
        {:error, :no_pending_change}

      %Account{pending_cycle_code: was_pending} ->
        Repo.update_all(
          from(a in Account, where: a.account_id == ^account_id),
          set: [pending_cycle_code: nil, cycle_change_effective_date: nil, cycle_change_proration_method: nil]
        )

        AuditLog.record(operator, "cms_cycle_resegmentation_cancelled", account_id, %{was_pending_to: was_pending})
        :ok
    end
  end

  @doc "All accounts with a pending, not-yet-effective cycle change, for a bank/logo scope."
  @spec list_pending(String.t(), String.t(), String.t()) :: [Account.t()]
  def list_pending(sys_id, bank_id, logo_id) do
    Repo.all(
      from a in Account,
        where:
          a.sys_id == ^sys_id and a.bank_id == ^bank_id and a.logo_id == ^logo_id and
            not is_nil(a.pending_cycle_code),
        order_by: [asc: a.cycle_change_effective_date]
    )
  end

  # ---------------------------------------------------------------------------
  # Apply (called daily from ApplyCycleResegmentationJob — always runs,
  # independent of which cycle_codes are due for EOD close today)
  # ---------------------------------------------------------------------------

  @doc """
  Applies every pending change whose `cycle_change_effective_date` has
  arrived (`<= as_of_date`) — real `cycle_code` flip, clears pending
  fields, stamps `cycle_code_changed_at`. Returns the count applied.
  """
  @spec apply_due_changes(Date.t()) :: non_neg_integer()
  def apply_due_changes(as_of_date \\ Date.utc_today()) do
    due =
      Repo.all(
        from a in Account,
          where: not is_nil(a.pending_cycle_code) and a.cycle_change_effective_date <= ^as_of_date,
          select: %{account_id: a.account_id, pending_cycle_code: a.pending_cycle_code}
      )

    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Enum.each(due, fn %{account_id: id, pending_cycle_code: new_code} ->
      Repo.update_all(
        from(a in Account, where: a.account_id == ^id),
        set: [
          cycle_code: new_code,
          pending_cycle_code: nil,
          cycle_change_effective_date: nil,
          cycle_code_changed_at: now
        ]
      )

      Logger.info("[CMS] Cycle resegmentation applied: account=#{id} cycle_code=#{new_code}")
    end)

    length(due)
  end

  @doc """
  For every distinct (sys_id, bank_id, logo_id) scope with active accounts
  where `resegmentation_mode` is `"auto"`, proposes a rebalance and
  schedules every proposed move immediately (system-authored, `operator:
  nil`). Called daily from `ApplyCycleResegmentationJob`, after
  `apply_due_changes/1`. `"manual"`-mode scopes (the default) are
  untouched — ops must review and apply via the admin screen.
  """
  @spec run_auto_rebalance() :: non_neg_integer()
  def run_auto_rebalance do
    scopes =
      Repo.all(
        from a in Account,
          where: a.account_status in ^@active_statuses,
          distinct: true,
          select: {a.sys_id, a.bank_id, a.logo_id}
      )

    Enum.reduce(scopes, 0, fn {sys_id, bank_id, logo_id}, acc ->
      case ModuleConfigEngine.get("cms", "resegmentation_mode", sys_id, bank_id, logo_id) do
        {:ok, "auto"} -> acc + auto_rebalance_scope(sys_id, bank_id, logo_id)
        _ -> acc
      end
    end)
  end

  defp auto_rebalance_scope(sys_id, bank_id, logo_id) do
    case propose_rebalance(sys_id, bank_id, logo_id) do
      {:ok, %{status: :imbalanced, moves: moves}} ->
        Enum.each(moves, fn %{account_id: id, to_cycle_code: to} ->
          schedule_resegmentation(id, to, nil)
        end)

        length(moves)

      _ ->
        0
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp allowed_codes(sys_id, bank_id, logo_id) do
    case ModuleConfigEngine.get("cms", "allowed_cycle_codes", sys_id, bank_id, logo_id) do
      {:ok, list} when is_list(list) and list != [] -> list
      _ -> @default_allowed_codes
    end
  end

  defp interval_cutoff(sys_id, bank_id, logo_id) do
    {:ok, min_months} =
      ModuleConfigEngine.get("cms", "resegmentation_min_interval_months", sys_id, bank_id, logo_id)

    NaiveDateTime.utc_now() |> NaiveDateTime.add(-min_months * 30 * 86_400, :second)
  end

  defp validate_different(%Account{cycle_code: same}, same), do: {:error, :same_cycle_code}
  defp validate_different(_account, _new_code), do: :ok

  defp validate_not_pending(%Account{pending_cycle_code: nil}), do: :ok
  defp validate_not_pending(_account), do: {:error, :already_pending}

  defp validate_allowed(account, new_code) do
    if new_code in allowed_codes(account.sys_id, account.bank_id, account.logo_id),
      do: :ok,
      else: {:error, :cycle_code_not_allowed}
  end

  defp validate_interval(%Account{cycle_code_changed_at: nil}), do: :ok

  defp validate_interval(%Account{cycle_code_changed_at: last} = account) do
    cutoff = interval_cutoff(account.sys_id, account.bank_id, account.logo_id)
    if NaiveDateTime.compare(last, cutoff) == :lt, do: :ok, else: {:error, :too_soon_since_last_change}
  end
end
