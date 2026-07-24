defmodule VmuCore.CMS.NotificationDispatcher.WebhookAdapter do
  @moduledoc """
  Webhook channel — POSTs to the bank's
  `cms.notification_gateway_config["webhook"]` URL, a system-to-system
  event subscriber rather than a person. `notification.recipient` is
  `nil`; `content_format` is always `"json"` for this channel (see
  `VmuCore.CMS.Notification.build_content/2`).
  """

  @behaviour VmuCore.CMS.NotificationDispatcher

  alias VmuCore.CMS.NotificationDispatcher.HttpGateway

  @impl true
  def send(notification, config), do: HttpGateway.post(config, notification)
end
