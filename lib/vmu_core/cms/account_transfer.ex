defmodule VmuCore.CMS.AccountTransfer do
  @moduledoc """
  LOGO-to-LOGO product migration (CMS-G3.2, FR-CMS-006).

  Moves an account to a different product within the same SYS/BANK:

  - Target LOGO (and BLOCK, which is logo-scoped) must exist.
  - Balances stay — buckets are amounts; pricing changes take effect through
    the new LOGO/BLOCK parameters at the next accrual (interest engine reads
    the cascade per run, so no re-price step is needed here).
  - Credit limit is **clamped to the new LOGO's `credit_limit_max`** when it
    exceeds it (clamp is logged + recorded in the event payload) and ASC is
    refreshed.
  - Full audit: `product_transfer` event with before/after + AuditLog.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator, CMS.NonMonetaryEvent}
  alias VmuCore.Shared.{LogoParameter, BlockParameter}
  alias VmuCore.ASM.AuditLog
  alias Decimal, as: D

  @system_operator_id "00000000-0000-0000-0000-000000000001"

  @doc """
  Transfer `account_id` to `new_logo_id` / `new_block_id`.

  Returns `{:ok, account, %{limit_clamped: boolean}}` or `{:error, reason}`.
  """
  @spec transfer(Ecto.UUID.t(), String.t(), String.t(), map() | nil) ::
          {:ok, Account.t(), map()} | {:error, term()}
  def transfer(account_id, new_logo_id, new_block_id, operator \\ nil) do
    with %Account{} = account <-
           Repo.get(Account, account_id) || {:error, :account_not_found},
         :ok <- check_status(account),
         :ok <- check_different(account, new_logo_id, new_block_id),
         {:ok, logo} <- fetch_logo(account, new_logo_id),
         :ok <- fetch_block(account, new_logo_id, new_block_id) do
      {new_limit, clamped} = clamp_limit(account.credit_limit, logo)

      Repo.update_all(
        from(a in Account, where: a.account_id == ^account_id),
        set: [logo_id: new_logo_id, block_id: new_block_id,
              credit_limit: new_limit, updated_at: NaiveDateTime.utc_now()]
      )

      if clamped do
        AccountStateCoordinator.refresh_limit(account_id, new_limit)

        Logger.warning("[AccountTransfer] Limit clamped for #{account_id}: " <>
                       "#{account.credit_limit} → #{new_limit} " <>
                       "(#{new_logo_id} credit_limit_max)")
      end

      NonMonetaryEvent.record(%{
        account_id:    account_id,
        event_type:    "product_transfer",
        old_value:     %{"logo_id" => account.logo_id, "block_id" => account.block_id,
                         "credit_limit" => to_string(account.credit_limit)},
        new_value:     %{"logo_id" => new_logo_id, "block_id" => new_block_id,
                         "credit_limit" => to_string(new_limit),
                         "limit_clamped" => clamped},
        operator_id:   (operator && operator.operator_id) || @system_operator_id,
        operator_role: if(operator, do: "SUPERVISOR", else: "SYSTEM")
      })

      AuditLog.record(operator, "product_transfer", account_id,
        %{from: "#{account.logo_id}/#{account.block_id}",
          to: "#{new_logo_id}/#{new_block_id}", limit_clamped: clamped})

      {:ok, Repo.get!(Account, account_id), %{limit_clamped: clamped}}
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp check_status(%Account{account_status: "ACTIVE"}), do: :ok
  defp check_status(%Account{account_status: status}), do: {:error, {:not_active, status}}

  defp check_different(%Account{logo_id: logo, block_id: block}, logo, block),
    do: {:error, :same_product}

  defp check_different(_, _, _), do: :ok

  defp fetch_logo(account, new_logo_id) do
    case Repo.get_by(LogoParameter,
           sys_id: account.sys_id, bank_id: account.bank_id, logo_id: new_logo_id) do
      nil -> {:error, {:logo_not_found, new_logo_id}}
      logo -> {:ok, logo}
    end
  end

  defp fetch_block(account, new_logo_id, new_block_id) do
    exists =
      Repo.exists?(
        from b in BlockParameter,
          where: b.sys_id == ^account.sys_id and b.bank_id == ^account.bank_id
             and b.logo_id == ^new_logo_id and b.block_id == ^new_block_id
      )

    if exists, do: :ok, else: {:error, {:block_not_found, new_block_id}}
  end

  defp clamp_limit(current_limit, logo) do
    case logo.credit_limit_max do
      %D{} = max ->
        if D.compare(current_limit, max) == :gt,
          do: {max, true},
          else: {current_limit, false}

      _ ->
        {current_limit, false}
    end
  end
end
