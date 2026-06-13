defmodule VmuCore.HCS.LimitController do
  @moduledoc """
  Dual-layer HCS limit enforcement: employee sub-limit + company credit pool.

  Called from AccountStateCoordinator.do_authorize/4 for every authorization.
  For non-HCS cards (no employee_card record), all checks return :ok immediately.

  Spending controls: MCC_BLOCK, MCC_ALLOW, CHANNEL_BLOCK, TXN_CAP.
  Company-level controls apply to all employee cards; card-level are additive.
  """

  alias VmuCore.HCS.{Company, EmployeeCard, SpendingControl}
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Called from AccountStateCoordinator.do_authorize/4.
  Returns :ok if all checks pass, {:error, reason} otherwise.
  For non-HCS cards returns :ok immediately.
  """
  def check_hcs_limits(employee_account_id, amount, channel, mcc) do
    case get_employee_card(employee_account_id) do
      nil ->
        :ok

      employee_card ->
        company = Repo.get!(Company, employee_card.company_id)
        amount_d = D.new(amount)

        with :ok <- check_company_active(company),
             :ok <- check_individual_limit(employee_card, amount_d),
             :ok <- check_company_pool(company, amount_d),
             :ok <- check_spending_controls(company.id, employee_card.id, amount_d, channel, mcc) do
          :ok
        end
    end
  end

  @doc """
  Debits both employee individual_limit and company pool after successful authorization.
  Called from AccountStateCoordinator after {:approved, ...}.
  No-op for non-HCS cards.
  """
  def debit_limits(employee_account_id, amount) do
    dec = D.new(amount)

    case get_employee_card(employee_account_id) do
      nil -> :ok
      employee_card ->
        Repo.transaction(fn ->
          Repo.update_all(
            from(ec in EmployeeCard, where: ec.id == ^employee_card.id),
            inc: [available_individual: D.negate(dec)]
          )
          Repo.update_all(
            from(c in Company, where: c.id == ^employee_card.company_id),
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
  def credit_limits(employee_account_id, amount) do
    inc = D.new(amount)

    case get_employee_card(employee_account_id) do
      nil -> :ok
      employee_card ->
        Repo.update_all(
          from(ec in EmployeeCard, where: ec.id == ^employee_card.id),
          inc: [available_individual: inc]
        )
        Repo.update_all(
          from(c in Company, where: c.id == ^employee_card.company_id),
          inc: [available_limit: inc]
        )
        :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp get_employee_card(employee_account_id) do
    Repo.one(
      from ec in EmployeeCard,
        where: ec.employee_account_id == ^employee_account_id and ec.status == "ACTIVE",
        limit: 1
    )
  end

  defp check_company_active(%{status: "ACTIVE"}), do: :ok
  defp check_company_active(_), do: {:error, :company_suspended}

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

  defp check_spending_controls(company_id, employee_card_id, amount, channel, mcc) do
    today = Date.utc_today()

    controls =
      Repo.all(
        from c in SpendingControl,
          where: c.company_id == ^company_id
            and c.status == "ACTIVE"
            and (is_nil(c.employee_card_id) or c.employee_card_id == ^employee_card_id)
            and c.effective_from <= ^today
            and (is_nil(c.effective_to) or c.effective_to >= ^today)
      )

    Enum.reduce_while(controls, :ok, fn control, :ok ->
      case apply_control(control, amount, channel, mcc) do
        :ok    -> {:cont, :ok}
        error  -> {:halt, error}
      end
    end)
  end

  defp apply_control(%{control_type: "MCC_BLOCK", mcc_codes: codes}, _amount, _channel, mcc) do
    if mcc in codes, do: {:error, :mcc_blocked}, else: :ok
  end

  defp apply_control(%{control_type: "MCC_ALLOW", mcc_codes: codes}, _amount, _channel, mcc) do
    if is_nil(mcc) or mcc in codes, do: :ok, else: {:error, :mcc_not_allowed}
  end

  defp apply_control(%{control_type: "CHANNEL_BLOCK", channels: blocked}, _amount, channel, _mcc) do
    ch = to_string(channel) |> String.upcase()
    if ch in blocked, do: {:error, :channel_blocked}, else: :ok
  end

  defp apply_control(%{control_type: "TXN_CAP", per_txn_cap: cap}, amount, _channel, _mcc)
       when not is_nil(cap) do
    if D.gt?(amount, cap), do: {:error, :per_txn_cap_exceeded}, else: :ok
  end

  defp apply_control(_, _, _, _), do: :ok
end
