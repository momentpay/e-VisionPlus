defmodule VmuCore.COL.DunningJob do
  @moduledoc """
  Oban job — generates and dispatches a dunning notice for a delinquent account.

  ## Treatment steps (COL-P3, FR-COL-011)

  Notice type and channels are read from `col.bucket_strategy_matrix` (scoped by
  the account's logo) instead of a hardcoded ladder — the config's `"default"`
  segment is used for now (no per-product segment selection yet). The step chosen
  is the one with the largest `day` <= the account's current DPD, so DPD values
  past the last defined day (e.g. 150/180, with only 30/60/90/120 defined by
  default) reuse that last entry as a catch-all — the same behavior the old
  hardcoded `notice_for_dpd(_)`/`channels_for_dpd(_)` catch-all clauses gave. If no
  step matches at all (DPD below the smallest defined day — shouldn't happen given
  `AgeBucketsJob` only hands off at DPD > 0 and the smallest default step is 30),
  no notice is dispatched.

  In production, the PDF is generated and queued to the print/mail vendor.

  ## Contact caps (COL-P2, FR-COL-013)

  Before dispatching to `"sms"` or `"email"` (the two channels with a configured
  regulatory cap — `col.contact_cap_sms_per_day` / `col.contact_cap_emails_per_week`),
  and before any channel, checks `col.contact_cooloff_hours` against the account's
  last contact attempt (any channel) via `VmuCore.COL.ContactHistory`. A capped or
  cooling-off channel is skipped (logged) rather than blocking the other channels
  in the same dispatch. Every channel that actually dispatches is recorded via
  `ContactHistory.record_attempt/3`.
  """

  use Oban.Worker, queue: :collections, max_attempts: 3

  require Logger
  alias VmuCore.Shared.Customer
  alias VmuCore.COL.{ContactHistory, BucketStrategy}

  # M2 (2026-07-17): config-injected — CMS isn't extracted yet.
  @repo Application.compile_env(:vmu_col, :repo, VmuCore.Repo)
  @account_schema Application.compile_env(:vmu_col, :cms_account_schema, VmuCore.CMS.Account)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "dpd_bucket" => dpd}}) do
    account  = @repo.get!(@account_schema, account_id)
    customer = @repo.get!(Customer, account.customer_id)

    case BucketStrategy.step_for_dpd(account, dpd) do
      nil ->
        Logger.info("[COL] No treatment step configured for account=#{account_id} dpd=#{dpd} — skipping")

      %{"notice_type" => notice_type, "channels" => channels} ->
        notice = build_notice(account, customer, notice_type, dpd)

        Enum.each(channels, fn channel ->
          if allowed_now?(account, channel) do
            dispatch_notice(channel, notice, account, customer)

            ContactHistory.record_attempt(account_id, channel,
              dpd_bucket: dpd, notes: "#{notice_type} via #{channel}")
          else
            Logger.info("[COL/#{channel}] account=#{account_id} skipped — contact cap or cool-off in effect")
          end
        end)

        Logger.warning("[COL] Dunning notice dispatched: account=#{account_id} DPD=#{dpd} type=#{notice_type}")
    end

    :ok
  end

  defp allowed_now?(account, channel) do
    ContactHistory.cooloff_ok?(account.account_id, account.sys_id, account.bank_id) and
      ContactHistory.within_cap?(account.account_id, channel, account.sys_id, account.bank_id)
  end

  defp build_notice(account, customer, notice_type, dpd) do
    %{
      type:              notice_type,
      dpd:               dpd,
      account_id:        account.account_id,
      customer_name:     "#{customer.first_name} #{customer.last_name}",
      outstanding:       account.open_to_buy,
      generated_at:      DateTime.utc_now()
    }
  end

  defp dispatch_notice("sms", notice, _account, customer) do
    Logger.info("[COL/SMS] #{customer.mobile_number}: DPD #{notice.dpd} reminder")
    # Production: SMS gateway client
  end

  defp dispatch_notice("email", notice, _account, customer) do
    Logger.info("[COL/Email] #{customer.email}: #{notice.type} notice")
    # Production: Swoosh email or Req to email API
  end

  defp dispatch_notice(channel, notice, _account, customer) do
    Logger.info("[COL/#{channel}] #{customer.last_name}: #{notice.type} — queued for print/mail")
    # Production: print vendor SFTP or REST API
  end
end
