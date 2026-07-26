defmodule VmuCore.HCS.LimitController do
  @moduledoc """
  Dual-layer HCS limit enforcement: card sub-limit + company credit pool.

  Called from AccountStateCoordinator.do_authorize/4 for every authorization.
  For non-HCS cards (no employee_card/fleet_card record), all checks return
  :ok immediately.

  Spending controls: MCC_BLOCK, MCC_ALLOW, CHANNEL_BLOCK, TXN_CAP, DAILY_CAP.
  Company-level controls apply to all cards of the company; card-level are
  additive.

  Generalized for fleet cards (Way4 parity plan Phase 1 item 3, 2026-07-25):
  `get_active_card/1` checks `EmployeeCard` first (by `employee_account_id`),
  then falls back to `FleetCard` (by `account_id`), returning a
  `{:employee, card} | {:fleet, card} | nil` tagged tuple. `EmployeeCard`
  and `FleetCard` deliberately share identical limit/control field names
  (`available_individual`, `can_withdraw_cash`, `daily_spend`,
  `daily_spend_date`, `company_id`, `id`) specifically so every check
  function below can pattern-match generically on either struct via a bare
  `%{field: ...}` pattern, without a struct-type check.
  """

  alias VmuCore.HCS.{Company, EmployeeCard, FleetCard, SpendingControl}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

  @doc """
  Called from AccountStateCoordinator.do_authorize/4.
  Returns :ok if all checks pass, {:error, reason} otherwise.
  For non-HCS cards returns :ok immediately.

  `cash_txn` (Way4 parity plan Phase 1 item 2, 2026-07-25) is the same
  `cash_transaction?/2` result `do_authorize/6` already computes for the
  account-level cash-OTB check — passed in rather than recomputed, so
  HCS's cash gate can never drift from the account-level definition of
  "this is a cash transaction."
  """
  def check_hcs_limits(account_id, amount, channel, mcc, cash_txn \\ false) do
    case get_active_card(account_id) do
      nil ->
        :ok

      {kind, card} ->
        company = Repo.get!(Company, card.company_id)
        amount_d = D.new(amount)

        with :ok <- check_company_active(company),
             :ok <- check_cash_access(card, cash_txn),
             :ok <- check_individual_limit(card, amount_d),
             :ok <- check_company_pool(company, amount_d),
             :ok <- check_spending_controls(company.id, kind, card, amount_d, channel, mcc) do
          :ok
        end
    end
  end

  @doc """
  Debits both card individual_limit and company pool after successful
  authorization. Called from AccountStateCoordinator after {:approved, ...}.
  No-op for non-HCS cards.

  Also maintains `daily_spend` (Way4 parity plan Phase 1 item 2) — the
  same choke point already used for `available_individual`/
  `available_limit`, rather than a separate ledger-sum query or a
  parallel counter with its own reset job. Rolls over to `amount` (not
  `daily_spend + amount`) when `daily_spend_date` isn't today, since a
  stale counter from a prior day means zero spent so far.
  """
  def debit_limits(account_id, amount) do
    dec = D.new(amount)

    case get_active_card(account_id) do
      nil -> :ok
      {kind, card} ->
        today = Date.utc_today()
        new_daily_spend =
          if card.daily_spend_date == today,
            do: D.add(card.daily_spend || D.new(0), dec),
            else: dec

        schema = card_schema(kind)

        Repo.transaction(fn ->
          Repo.update_all(
            from(c in schema, where: c.id == ^card.id),
            inc: [available_individual: D.negate(dec)],
            set: [daily_spend: new_daily_spend, daily_spend_date: today]
          )
          Repo.update_all(
            from(c in Company, where: c.id == ^card.company_id),
            inc: [available_limit: D.negate(dec)]
          )
        end)
        :ok
    end
  end

  @doc """
  Restores limits on repayment or reversal.
  Called from RepaymentDistributor.distribute/2 after posting payment.
  No-op for non-HCS cards.
  """
  def credit_limits(account_id, amount) do
    inc = D.new(amount)

    case get_active_card(account_id) do
      nil -> :ok
      {kind, card} ->
        schema = card_schema(kind)

        Repo.update_all(
          from(c in schema, where: c.id == ^card.id),
          inc: [available_individual: inc]
        )
        Repo.update_all(
          from(c in Company, where: c.id == ^card.company_id),
          inc: [available_limit: inc]
        )
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp get_active_card(account_id) do
    case Repo.one(
           from ec in EmployeeCard,
             where: ec.employee_account_id == ^account_id and ec.status == "ACTIVE",
             limit: 1
         ) do
      %EmployeeCard{} = card ->
        {:employee, card}

      nil ->
        case Repo.one(
               from fc in FleetCard,
                 where: fc.account_id == ^account_id and fc.status == "ACTIVE",
                 limit: 1
             ) do
          %FleetCard{} = card -> {:fleet, card}
          nil -> nil
        end
    end
  end

  defp card_schema(:employee), do: EmployeeCard
  defp card_schema(:fleet), do: FleetCard

  defp check_company_active(%{status: "ACTIVE"}), do: :ok
  defp check_company_active(_), do: {:error, :company_suspended}

  # Found live 2026-07-25: can_withdraw_cash existed on the schema but was
  # never read anywhere — every employee card could take cash regardless
  # of the field.
  defp check_cash_access(_card, false), do: :ok
  defp check_cash_access(%{can_withdraw_cash: true}, true), do: :ok
  defp check_cash_access(%{can_withdraw_cash: _}, true), do: {:error, :cash_access_blocked}

  defp check_individual_limit(%{available_individual: avail}, amount) do
    if D.lt?(avail, amount),
      do: {:error, :individual_limit_exceeded},
      else: :ok
  end

  defp check_company_pool(%{available_limit: avail}, amount) do
    if D.lt?(avail, amount),
      do: {:error, :company_pool_exhausted},
      else: :ok
  end

  defp check_spending_controls(company_id, kind, card, amount, channel, mcc) do
    today = Date.utc_today()

    card_match =
      case kind do
        :employee -> dynamic([c], is_nil(c.employee_card_id) or c.employee_card_id == ^card.id)
        :fleet     -> dynamic([c], is_nil(c.fleet_card_id) or c.fleet_card_id == ^card.id)
      end

    base_match =
      dynamic(
        [c],
        c.company_id == ^company_id and c.status == "ACTIVE" and
          c.effective_from <= ^today and
          (is_nil(c.effective_to) or c.effective_to >= ^today)
      )

    controls =
      Repo.all(from c in SpendingControl, where: ^dynamic([c], ^base_match and ^card_match))

    # Today's spend-so-far is 0 if the card's counter is stale (last
    # touched on an earlier day) — computed once here, not per-control.
    spent_today =
      if card.daily_spend_date == today,
        do: card.daily_spend || D.new(0),
        else: D.new(0)

    Enum.reduce_while(controls, :ok, fn control, :ok ->
      case apply_control(control, amount, channel, mcc, spent_today) do
        :ok    -> {:cont, :ok}
        error  -> {:halt, error}
      end
    end)
  end

  defp apply_control(%{control_type: "MCC_BLOCK", mcc_codes: codes}, _amount, _channel, mcc, _spent) do
    if mcc in codes, do: {:error, :mcc_blocked}, else: :ok
  end

  defp apply_control(%{control_type: "MCC_ALLOW", mcc_codes: codes}, _amount, _channel, mcc, _spent) do
    if is_nil(mcc) or mcc in codes, do: :ok, else: {:error, :mcc_not_allowed}
  end

  defp apply_control(%{control_type: "CHANNEL_BLOCK", channels: blocked}, _amount, channel, _mcc, _spent) do
    ch = to_string(channel) |> String.upcase()
    if ch in blocked, do: {:error, :channel_blocked}, else: :ok
  end

  defp apply_control(%{control_type: "TXN_CAP", per_txn_cap: cap}, amount, _channel, _mcc, _spent)
       when not is_nil(cap) do
    if D.gt?(amount, cap), do: {:error, :per_txn_cap_exceeded}, else: :ok
  end

  # Found live 2026-07-25: DAILY_CAP was schema-valid and documented as a
  # control type but had no enforcement clause at all — a silent no-op.
  defp apply_control(%{control_type: "DAILY_CAP", daily_cap: cap}, amount, _channel, _mcc, spent_today)
       when not is_nil(cap) do
    if D.gt?(D.add(spent_today, amount), cap), do: {:error, :daily_cap_exceeded}, else: :ok
  end

  defp apply_control(_, _, _, _, _), do: :ok
end
