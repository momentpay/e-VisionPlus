defmodule VmuCore.CMS.Notification do
  @moduledoc """
  Context for outbound payment-receipt notifications (FR-CMS-070).

  Fans a single event out across every channel the account's bank has
  opted into (`cms.notification_channels_enabled`), dispatching through
  `VmuCore.CMS.NotificationDispatcher`'s per-channel adapter and logging
  every attempt to `cms_notification_log` (idempotent on
  `"notification:<event_type>:<reference>:<channel>"` — a redelivered
  payment webhook can't double-notify).

  Best-effort by design: called from `VmuCore.CMS.PaymentIntake` *after*
  its DB transaction commits, exactly like the existing OTB-restore call —
  a notification-gateway outage must never roll back or block a payment.
  Every path here returns `:ok`; failures are logged to the row's
  `status`/`response` fields for ops to see, not raised.
  """

  require Logger

  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, NotificationLog, NotificationDispatcher}
  alias VmuCore.Shared.{Customer, ModuleConfigEngine}
  alias Decimal, as: D

  @doc """
  Fire payment-receipt notifications for `account` across every channel
  its bank has enabled. `details` is
  `%{amount:, allocated:, remainder:, payment_channel:, reference:}`.
  Always returns `:ok`.
  """
  @spec notify_payment_receipt(Account.t(), map()) :: :ok
  def notify_payment_receipt(%Account{} = account, details) do
    case ModuleConfigEngine.get("cms", "notification_channels_enabled",
                                 account.sys_id, account.bank_id, account.logo_id) do
      {:ok, channels} when is_list(channels) and channels != [] ->
        {:ok, gateway_config} =
          ModuleConfigEngine.get("cms", "notification_gateway_config",
                                  account.sys_id, account.bank_id, account.logo_id)

        customer = Repo.get(Customer, account.customer_id)

        Enum.each(channels, fn channel ->
          dispatch_one(account, customer, channel, gateway_config, details)
        end)

      _ ->
        :ok
    end

    :ok
  end

  @doc "All notification attempts for an account, newest first."
  @spec list_for_account(Ecto.UUID.t()) :: [NotificationLog.t()]
  def list_for_account(account_id), do: NotificationLog.list_for_account(account_id)

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp dispatch_one(account, customer, channel, gateway_config, details) do
    key = "notification:payment_receipt:#{details.reference}:#{channel}"

    if Repo.get_by(NotificationLog, idempotency_key: key) do
      :ok
    else
      {content, content_format} = build_content(channel, account, details)
      channel_config = Map.get(gateway_config, channel, %{})

      notification = %{
        content: content,
        content_format: content_format,
        channel: channel,
        priority: "normal",
        recipient: recipient_for(channel, customer),
        event_type: "payment_receipt",
        reference: details.reference
      }

      {status, response} = call_adapter(channel, notification, channel_config)

      %NotificationLog{}
      |> NotificationLog.changeset(%{
        account_id: account.account_id,
        event_type: "payment_receipt",
        channel: channel,
        content: content,
        content_format: content_format,
        priority: "normal",
        status: status,
        response: response,
        idempotency_key: key
      })
      |> Repo.insert()

      :ok
    end
  end

  defp call_adapter(channel, notification, channel_config) do
    case NotificationDispatcher.adapter(channel) do
      nil ->
        {"SKIPPED", %{"reason" => "unknown_channel"}}

      adapter ->
        case adapter.send(notification, channel_config) do
          {:ok, resp} ->
            {"SENT", to_response_map(resp)}

          {:error, :no_url} ->
            {"SKIPPED", %{"reason" => "not_configured"}}

          {:error, reason} ->
            Logger.warning("[CMS.Notification] #{channel} dispatch failed: #{inspect(reason)}")
            {"FAILED", %{"reason" => inspect(reason)}}
        end
    end
  end

  defp to_response_map(resp) when is_map(resp), do: resp
  defp to_response_map(resp), do: %{"raw" => inspect(resp)}

  defp recipient_for("email", %Customer{email: email}), do: email
  defp recipient_for(c, %Customer{mobile_country: cc, mobile_number: num}) when c in ["sms", "whatsapp"],
    do: "#{cc}#{num}"
  defp recipient_for(_channel, _customer), do: nil

  # webhook is a system subscriber, not a person — always structured JSON.
  # email/sms/whatsapp get a short human-readable text summary.
  defp build_content("webhook", account, details) do
    body =
      Jason.encode!(%{
        event: "payment_receipt",
        account_id: account.account_id,
        amount: D.to_string(details.amount),
        allocated: D.to_string(details.allocated),
        remainder: D.to_string(details.remainder),
        payment_channel: details.payment_channel,
        reference: details.reference
      })

    {body, "json"}
  end

  defp build_content(_channel, _account, details) do
    text =
      "Payment of #{D.to_string(details.amount)} received via #{details.payment_channel} " <>
        "(ref #{details.reference}). Thank you."

    {text, "text"}
  end
end
