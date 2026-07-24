defmodule VmuCore.CMS.NotificationDispatcher.WhatsappAdapter do
  @moduledoc """
  WhatsApp channel — POSTs to the bank's
  `cms.notification_gateway_config["whatsapp"]` URL (their own WhatsApp
  Business Solution Provider middleware — template approval, session
  windows, etc. are that gateway's concern, not this dispatcher's).
  `notification.recipient` is the customer's E.164 mobile number.
  """

  @behaviour VmuCore.CMS.NotificationDispatcher

  alias VmuCore.CMS.NotificationDispatcher.HttpGateway

  @impl true
  def send(notification, config), do: HttpGateway.post(config, notification)
end
