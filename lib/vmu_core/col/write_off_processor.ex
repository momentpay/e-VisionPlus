defmodule VmuCore.COL.WriteOffProcessor do
  @moduledoc """
  Processes credit card account write-offs at 180+ DPD or by manual trigger.

  Write-off steps (all within a DB transaction):
    1. Move balance to charged-off GL bucket (Dr: Charged-off receivable / Cr: Retail receivable)
    2. Set account_status to WRITTEN_OFF
    3. Update collection case status to WRITTEN_OFF
    4. Zero the account's open_to_buy
    5. Refresh AccountStateCoordinator (account will decline all new auths)
    6. Post a recoveries tracking entry (for post-write-off partial repayments)

  Recovery tracking:
    Any payments received after write-off are credited to the recovery GL bucket
    (Dr: Cash / Cr: Recovery income). The original write-off is not reversed.
  """

  require Logger
  import Ecto.Query

  alias VmuCore.COL.CollectionCase
  alias Decimal, as: D

  # M2 (2026-07-17): config-injected — CMS isn't extracted yet.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)
  @account_state_coordinator Application.compile_env(:vmu_col, :cms_account_state_coordinator, VmuCore.CMS.AccountStateCoordinator)
  @internal_gl_poster Application.compile_env(:vmu_col, :cms_internal_gl_poster, VmuCore.CMS.InternalGlPoster)

  # M5 Phase 2 (2026-07-18) — reconciled onto WalletGl.ChartOfAccounts;
  # "5001" previously collided with CardAccountCodes' unrelated "5001
  # Interchange/MDR Expense".
  @gl_charged_off "1005"  # Charged-off receivable
  @gl_retail_recv "1001"  # Retail receivable

  @doc """
  Write off a delinquent account.
  Returns {:ok, %{write_off_amount: Decimal.t()}} or {:error, reason}.
  """
  def write_off(account_id) do
    @repo.transaction(fn ->
      account = @repo.get!(@account_schema, account_id)

      unless account.account_status in ["DELINQUENT", "BLOCKED", "SUSPENDED"] do
        @repo.rollback(:account_not_eligible)
      end

      write_off_amount = D.sub(account.credit_limit, account.open_to_buy)

      if D.compare(write_off_amount, D.new(0)) != :gt do
        @repo.rollback(:zero_balance)
      end

      # 1. GL entry — move to charged-off bucket
      idempotency_key = "WRITEOFF-#{account_id}-#{Date.utc_today()}"
      @internal_gl_poster.post(%{
        account_id:       account_id,
        idempotency_key:  idempotency_key,
        transaction_code: "ADJUSTMENT",
        dr_amount:        write_off_amount,
        cr_amount:        write_off_amount,
        gl_account_dr:    @gl_charged_off,
        gl_account_cr:    @gl_retail_recv,
        posting_date:     Date.utc_today(),
        value_date:       Date.utc_today(),
        narrative:        "Write-off — account #{account_id}"
      })

      # 2. Update account
      @repo.update_all(
        from(a in @account_schema, where: a.account_id == ^account_id),
        set: [
          account_status: "WRITTEN_OFF",
          open_to_buy:    D.new(0),
          updated_at:     NaiveDateTime.utc_now()
        ]
      )

      # 3. Update collection case
      @repo.update_all(
        from(c in CollectionCase,
          where: c.account_id == ^account_id and c.status in ["OPEN", "AGENCY"]),
        set: [
          status:          "WRITTEN_OFF",
          write_off_date:  Date.utc_today(),
          write_off_amount: write_off_amount,
          updated_at:      NaiveDateTime.utc_now()
        ]
      )

      # 4. Refresh coordinator — account will now decline all new auths
      @account_state_coordinator.refresh(account_id)

      Logger.warning("[COL] Written off: account=#{account_id} amount=#{write_off_amount}")
      %{write_off_amount: write_off_amount}
    end)
  end

  @doc """
  Post a recovery payment (received after write-off).
  Does NOT reverse the write-off — posts to recovery income GL.
  """
  def post_recovery(account_id, amount, source_ref) do
    @internal_gl_poster.post(%{
      account_id:       account_id,
      idempotency_key:  "RECOVERY-#{source_ref}",
      transaction_code: "PAYMENT",
      dr_amount:        amount,
      cr_amount:        amount,
      gl_account_dr:    "3001",   # Cash/settlement account (Payment / Adjustment Clearing)
      gl_account_cr:    "4004",   # Recovery income
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today(),
      narrative:        "Recovery payment ref=#{source_ref}",
      source_ref:       source_ref
    })
  end
end
