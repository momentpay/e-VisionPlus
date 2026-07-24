defmodule VmuCore.CMS.NotificationDispatcher do
  @moduledoc """
  Behaviour contract for outbound notification channels (FR-CMS-070).

  Mirrors `VmuCore.DPS.EvidenceStore`'s shape: a plain `@callback` per
  channel adapter plus per-channel string→module resolution — but every
  channel here is real, working code, not a stub. There is no specific
  vendor to integrate against (unlike FAS's HSM or DPS's S3/Azure evidence
  backends, which need a vendor SDK this project doesn't have yet): each
  channel is just an HTTP POST to a bank-configured gateway URL
  (`cms.notification_gateway_config`, Module Configuration Framework) —
  the bank's own middleware, or a vendor's REST API directly, is
  responsible for the actual delivery to email/SMS/WhatsApp/webhook
  subscribers. If a channel's config has no URL, `VmuCore.CMS.Notification`
  skips it (status `SKIPPED`) rather than calling the adapter at all.
  """

  @doc """
  Send one notification. `notification` is
  `%{content:, content_format:, channel:, priority:, recipient:, event_type:, reference:}`.
  `config` is the channel's `cms.notification_gateway_config` sub-map
  (`%{"url" => ..., "headers" => %{...}}`).
  """
  @callback send(notification :: map(), config :: map()) ::
              {:ok, term()} | {:error, term()}

  @adapters %{
    "email"    => __MODULE__.EmailAdapter,
    "sms"      => __MODULE__.SmsAdapter,
    "whatsapp" => __MODULE__.WhatsappAdapter,
    "webhook"  => __MODULE__.WebhookAdapter
  }

  @doc "Resolves the adapter module for a notification channel, or nil for an unknown one."
  @spec adapter(String.t()) :: module() | nil
  def adapter(channel), do: Map.get(@adapters, channel)
end
