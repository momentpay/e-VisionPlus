defmodule VmuCore.CMS.NotificationDispatcher.EmailAdapter do
  @moduledoc """
  Email channel — POSTs to the bank's `cms.notification_gateway_config["email"]`
  URL (their own mailer middleware, or a vendor's REST API like SendGrid/SES
  directly). `notification.recipient` is the customer's email address.
  """

  @behaviour VmuCore.CMS.NotificationDispatcher

  alias VmuCore.CMS.NotificationDispatcher.HttpGateway

  @impl true
  def send(notification, config), do: HttpGateway.post(config, notification)
end
