defmodule VmuCore.CAM.Auth do
  @moduledoc """
  Cardholder Access Management (CAM) Phase F1 (2026-08-02) — the first
  cardholder-facing (not operator, not app-level ServiceAccount)
  authentication in this codebase. Mobile-number + OTP, no password.

  Reuses `CMS.NotificationDispatcher`'s real SMS adapter exactly the way
  `CMS.Notification.notify_payment_receipt/2` does (bank-scoped
  `cms.notification_gateway_config` → `NotificationDispatcher.adapter/1` →
  `adapter.send/2`) rather than introducing a second dispatch path.
  """

  require Logger

  alias VmuCore.Repo
  alias VmuCore.Shared.{Customer, ModuleConfigEngine}
  alias VmuCore.CMS.NotificationDispatcher
  alias VmuCore.CAM.{OtpChallenges, CustomerSession}

  @doc """
  Looks up the customer by `(sys_id, bank_id, mobile_number)` and sends an
  OTP if found. Always returns `:ok` regardless of whether a matching
  customer exists, to avoid leaking which mobile numbers are enrolled.
  """
  @spec request_otp(String.t(), String.t(), String.t()) :: :ok
  def request_otp(sys_id, bank_id, mobile_number) do
    case find_customer(sys_id, bank_id, mobile_number) do
      nil ->
        :ok

      customer ->
        {:ok, code, _challenge} = OtpChallenges.create(customer.customer_id)
        dispatch_sms(customer, code)
        :ok
    end
  end

  @doc """
  Verifies the code and, on success, issues a session token.
  """
  @spec verify_otp(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, String.t(), Customer.t()} | {:error, :invalid_code | :expired | :not_found | :too_many_attempts}
  def verify_otp(sys_id, bank_id, mobile_number, code) do
    with customer when not is_nil(customer) <- find_customer(sys_id, bank_id, mobile_number),
         :ok <- OtpChallenges.verify(customer.customer_id, code) do
      {:ok, CustomerSession.issue(customer), customer}
    else
      nil -> {:error, :not_found}
      error -> error
    end
  end

  defp find_customer(sys_id, bank_id, mobile_number) do
    Repo.get_by(Customer, sys_id: sys_id, bank_id: bank_id, mobile_number: mobile_number)
  end

  defp dispatch_sms(customer, code) do
    case ModuleConfigEngine.get("cms", "notification_gateway_config", customer.sys_id, customer.bank_id) do
      {:ok, gateway_config} ->
        channel_config = Map.get(gateway_config, "sms", %{})
        notification = %{
          content: "Your Kosa login code is #{code}. It expires in 5 minutes.",
          content_format: "text",
          channel: "sms",
          priority: "high",
          recipient: "#{customer.mobile_country}#{customer.mobile_number}",
          event_type: "cam_login_otp",
          reference: customer.customer_id
        }

        case NotificationDispatcher.adapter("sms").send(notification, channel_config) do
          {:ok, _resp} -> :ok
          {:error, reason} -> Logger.warning("[CAM.Auth] OTP SMS dispatch failed: #{inspect(reason)}")
        end

      _ ->
        Logger.warning("[CAM.Auth] OTP not sent — no cms.notification_gateway_config for #{customer.sys_id}/#{customer.bank_id}")
    end
  end
end
