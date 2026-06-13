defmodule VmuCore.COL.DunningJob do
  @moduledoc """
  Oban job — generates and dispatches a dunning notice for a delinquent account.

  Dunning notice content and channel vary by DPD bucket:
    30 DPD  → SMS reminder + email
    60 DPD  → Formal letter (PDF generated, mailed)
    90 DPD  → Formal demand letter (PDF generated, mailed + courier)
    120 DPD → Legal notice (PDF generated, registered mail + agency file)

  In production, the PDF is generated and queued to the print/mail vendor.
  The notice content is templated from the block_parameters dunning_template_id.
  """

  use Oban.Worker, queue: :collections, max_attempts: 3

  require Logger
  alias VmuCore.{Repo, CMS.Account}
  alias VmuCore.Shared.Customer

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"account_id" => account_id, "dpd_bucket" => dpd}}) do
    account  = Repo.get!(Account, account_id)
    customer = Repo.get!(Customer, account.customer_id)

    notice_type = notice_for_dpd(dpd)
    channels    = channels_for_dpd(dpd)

    notice = build_notice(account, customer, notice_type, dpd)

    Enum.each(channels, fn channel ->
      dispatch_notice(channel, notice, account, customer)
    end)

    Logger.warning("[COL] Dunning notice dispatched: account=#{account_id} DPD=#{dpd} type=#{notice_type}")
    :ok
  end

  defp notice_for_dpd(dpd) when dpd <= 30,  do: :soft_reminder
  defp notice_for_dpd(dpd) when dpd <= 60,  do: :formal_notice
  defp notice_for_dpd(dpd) when dpd <= 90,  do: :demand_letter
  defp notice_for_dpd(_),                   do: :legal_notice

  defp channels_for_dpd(dpd) when dpd <= 30, do: [:sms, :email]
  defp channels_for_dpd(dpd) when dpd <= 60, do: [:email, :letter]
  defp channels_for_dpd(dpd) when dpd <= 90, do: [:letter, :courier]
  defp channels_for_dpd(_),                  do: [:letter, :courier, :registered_mail]

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

  defp dispatch_notice(:sms, notice, _account, customer) do
    Logger.info("[COL/SMS] #{customer.mobile_number}: DPD #{notice.dpd} reminder")
    # Production: SMS gateway client
  end

  defp dispatch_notice(:email, notice, _account, customer) do
    Logger.info("[COL/Email] #{customer.email}: #{notice.type} notice")
    # Production: Swoosh email or Req to email API
  end

  defp dispatch_notice(channel, notice, _account, customer) do
    Logger.info("[COL/#{channel}] #{customer.last_name}: #{notice.type} — queued for print/mail")
    # Production: print vendor SFTP or REST API
  end
end
