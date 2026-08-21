defmodule VmuCore.CMS.NotificationDispatcher.SmsAdapter do
  @moduledoc """
  SMS channel — POSTs to the bank's `cms.notification_gateway_config["sms"]`
  URL (their own SMS aggregator middleware). `notification.recipient` is
  the customer's E.164 mobile number.
  """

  @behaviour VmuCore.CMS.NotificationDispatcher

  alias VmuCore.CMS.NotificationDispatcher.HttpGateway

  @impl true
  def send(notification, config), do: HttpGateway.post(config, notification)
end
