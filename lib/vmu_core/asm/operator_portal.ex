defmodule VmuCore.ASM.OperatorPortal do
  @moduledoc """
  ASM (Account & System Management) operator portal facade.

  Wraps privileged system-management operations behind a role-checked interface.
  The Phoenix LiveView UI mounts this module's functions directly — no REST layer.

  FAPI 2.0 / OpenID Connect token validation is enforced at the Phoenix router
  level (plug VmuCore.ASM.AuthPlug). This module assumes the caller is already
  authenticated and only enforces role-level authorization.

  Operator roles (least → most privileged):
    :agent     → read-only account lookup, transaction history
    :supervisor → above + manual adjustments, fee waivers
    :manager   → above + limit changes, write-offs, account closure
    :sysadmin  → above + parameter table updates, EOD override

  All privileged write operations are written to the cms_operator_audit log
  (append-only, no soft deletes).
  """

  require Logger
  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.InternalGlPoster}
  alias VmuCore.CMS.AccountStateCoordinator
  alias VmuCore.Shared.ParameterEngine
  alias Decimal, as: D

  @role_hierarchy [:agent, :supervisor, :manager, :sysadmin]

  # ---------------------------------------------------------------------------
  # Account lookup (read-only — any role)
  # ---------------------------------------------------------------------------

  @doc "Fetch full account summary for operator display."
  def get_account_summary(account_id, operator) do
    with :ok <- require_role(operator, :agent) do
      account = Repo.get!(Account, account_id)
      bucket  = Repo.get_by(BalanceBucket, account_id: account_id)

      summary = %{
        account_id:         account.account_id,
        pan_token:          account.pan_token,
        account_status:     account.account_status,
        credit_limit:       account.credit_limit,
        open_to_buy:        account.open_to_buy,
        delinquency_bucket: account.delinquency_bucket,
        cycle_code:         account.cycle_code,
        balances:           bucket
      }

      audit(operator, :account_view, account_id, %{})
      {:ok, summary}
    end
  end

  # ---------------------------------------------------------------------------
  # Fee waiver (supervisor+)
  # ---------------------------------------------------------------------------

  @doc "Waive a fee by posting a reversal GL entry."
  def waive_fee(account_id, amount, reason, operator) do
    with :ok <- require_role(operator, :supervisor),
         :ok <- validate_amount(amount) do

      idempotency_key = "WVFEE-#{account_id}-#{:os.system_time(:millisecond)}"

      entry = %{
        account_id:       account_id,
        transaction_code: "ADJUSTMENT",
        debit_gl:         "4001",  # fee income GL
        credit_gl:        "1001",  # receivables GL
        amount:           amount,
        description:      "Fee waiver: #{reason}",
        idempotency_key:  idempotency_key,
        posted_by:        operator.operator_id
      }

      with {:ok, _} <- InternalGlPoster.post(entry) do
        AccountStateCoordinator.credit_open_to_buy(account_id, amount)
        audit(operator, :fee_waiver, account_id, %{amount: amount, reason: reason})
        Logger.info("[ASM] Fee waiver posted: account=#{account_id} amount=#{amount} by=#{operator.id}")
        :ok
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Credit limit adjustment (manager+)
  # ---------------------------------------------------------------------------

  @doc "Adjust the credit limit for an account."
  def adjust_limit(account_id, new_limit, reason, operator) do
    with :ok <- require_role(operator, :manager),
         :ok <- validate_amount(new_limit) do

      account = Repo.get!(Account, account_id)
      old_limit = account.credit_limit
      delta     = D.sub(new_limit, old_limit)

      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [credit_limit: new_limit, updated_at: NaiveDateTime.utc_now()]
      )

      AccountStateCoordinator.refresh_limit(account_id, new_limit)

      audit(operator, :limit_change, account_id, %{
        old_limit: old_limit, new_limit: new_limit, delta: delta, reason: reason
      })

      Logger.info("[ASM] Limit adjusted: account=#{account_id} #{old_limit}→#{new_limit} by=#{operator.id}")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Account closure (manager+)
  # ---------------------------------------------------------------------------

  @doc "Close an account (sets status=CLOSED, zeroes OTB)."
  def close_account(account_id, reason, operator) do
    with :ok <- require_role(operator, :manager) do
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [account_status: "CLOSED", open_to_buy: D.new(0), updated_at: NaiveDateTime.utc_now()]
      )

      AccountStateCoordinator.notify_status_change(account_id, "CLOSED")
      audit(operator, :account_closure, account_id, %{reason: reason})
      Logger.info("[ASM] Account closed: #{account_id} reason=#{reason} by=#{operator.id}")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Account block / unblock (supervisor+)
  # ---------------------------------------------------------------------------

  @doc "Block an account — sets status=BLOCKED, halts further authorizations."
  def block_account(account_id, reason, operator) do
    with :ok <- require_role(operator, :supervisor) do
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [account_status: "BLOCKED", updated_at: NaiveDateTime.utc_now()]
      )
      AccountStateCoordinator.notify_status_change(account_id, "BLOCKED")
      audit(operator, :account_block, account_id, %{reason: reason})
      Logger.info("[ASM] Account blocked: #{account_id} reason=#{reason} by=#{operator.id}")
      :ok
    end
  end

  @doc "Reactivate a blocked account — sets status=ACTIVE."
  def unblock_account(account_id, reason, operator) do
    with :ok <- require_role(operator, :supervisor) do
      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [account_status: "ACTIVE", updated_at: NaiveDateTime.utc_now()]
      )
      AccountStateCoordinator.notify_status_change(account_id, "ACTIVE")
      audit(operator, :account_unblock, account_id, %{reason: reason})
      Logger.info("[ASM] Account unblocked: #{account_id} reason=#{reason} by=#{operator.id}")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Parameter update (sysadmin only)
  # ---------------------------------------------------------------------------

  @doc "Update a ParameterEngine key — restricted to sysadmin role."
  def update_parameter(sys_id, bank_id, logo_id, block_id, key, value, operator) do
    with :ok <- require_role(operator, :sysadmin) do
      ParameterEngine.put(sys_id, bank_id, logo_id, block_id, key, value)
      audit(operator, :parameter_update, "#{sys_id}/#{bank_id}/#{logo_id}/#{block_id}",
            %{key: key, value: value})
      Logger.info("[ASM] Parameter updated: #{key}=#{value} by=#{operator.id}")
      :ok
    end
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp require_role(operator, required_role) do
    required_idx = Enum.find_index(@role_hierarchy, &(&1 == required_role))
    operator_idx = Enum.find_index(@role_hierarchy, &(&1 == operator.role))

    if operator_idx >= required_idx,
      do: :ok,
      else: {:error, :insufficient_role}
  end

  defp validate_amount(amount) do
    if D.gt?(amount, D.new(0)),
      do: :ok,
      else: {:error, :invalid_amount}
  end

  defp audit(operator, action, subject, details) do
    Repo.insert_all("cms_operator_audit", [%{
      operator_id: operator.id,
      operator_role: to_string(operator.role),
      action:      to_string(action),
      subject:     subject,
      details:     Jason.encode!(details),
      performed_at: NaiveDateTime.utc_now(),
      inserted_at: NaiveDateTime.utc_now()
    }])
  end
end
