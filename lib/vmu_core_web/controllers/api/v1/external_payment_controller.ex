defmodule VmuCoreWeb.Api.V1.ExternalPaymentController do
  @moduledoc """
  External wallet-out payment API — A2A (W011) / Instant Payments (W012),
  Digital Wallet Phase W6 (2026-07-29). Thin HTTP wrapper over
  `CMS.ExternalPaymentCommand`, no business logic here — same convention
  as `Api.V1.KycController`. This is the mobile-app-facing surface for
  both rail types; which rail actually moves the money is still an
  external vendor decision (`CMS.RailProvider`, `CMS.RailProviders.Stub`
  until one is chosen) — the API contract and risk gate exist regardless.

  Every mutating action is audited via `ASM.AuditLog.record/4`, same
  posture as `KycController`.
  """

  use Phoenix.Controller, formats: [:json]

  alias VmuCore.CMS.{ExternalPaymentCommand, ExternalPayments}
  alias VmuCore.ASM.AuditLog
  alias VmuCoreWeb.Plugs.ApiV1Auth
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @doc "POST /api/v1/wallet/payments — initiate an A2A or Instant Payment out of a wallet."
  def create(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "wallet:write")

    if conn.halted do
      conn
    else
      with {:ok, attrs} <- build_attrs(params) do
        case ExternalPaymentCommand.initiate(attrs) do
          {:ok, payment} ->
            AuditLog.record(nil, "external_payment_api_initiate", "external_payment:#{payment.id}", %{
              service_account: conn.assigns.service_account.name,
              rail_type: payment.rail_type
            })

            conn |> put_status(201) |> json(ErrorEnvelope.ok(%{payment: payment_json(payment)}))

          {:error, {:risk_blocked, decision, payment}} ->
            ErrorEnvelope.send(conn, 422, "risk_blocked", "Blocked by risk screening (#{decision}) — payment #{payment.id} recorded, no funds moved")

          {:error, {:not_active, payment}} ->
            ErrorEnvelope.send(conn, 422, "wallet_account_not_active", "This wallet account isn't active — payment #{payment.id} recorded")

          {:error, {:insufficient_funds, payment}} ->
            ErrorEnvelope.send(conn, 422, "insufficient_funds", "Insufficient wallet balance — payment #{payment.id} recorded")

          {:error, {{:rail_error, :rail_not_configured}, payment}} ->
            ErrorEnvelope.send(conn, 503, "rail_not_configured", "No payment rail is configured for #{attrs.rail_type} yet — payment #{payment.id} recorded, wallet not debited")

          {:error, {{:rail_error, reason}, payment}} ->
            ErrorEnvelope.send(conn, 502, "rail_error", "The payment rail declined this request: #{inspect(reason)} — payment #{payment.id} recorded, wallet not debited")

          {:error, changeset} ->
            ErrorEnvelope.send(conn, 422, "validation_failed", changeset_error_message(changeset))
        end
      else
        {:error, message} -> ErrorEnvelope.send(conn, 422, "missing_params", message)
      end
    end
  end

  @doc "GET /api/v1/wallet/payments/:id — status check."
  def show(conn, %{"id" => id}) do
    conn = ApiV1Auth.require_scope(conn, "wallet:read")

    if conn.halted do
      conn
    else
      case ExternalPayments.get(id) do
        nil -> ErrorEnvelope.send(conn, 404, "payment_not_found", "No external payment with that id")
        payment -> json(conn, ErrorEnvelope.ok(%{payment: payment_json(payment)}))
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp build_attrs(%{"wallet_account_id" => wa, "rail_type" => rt, "amount" => amount, "currency" => cur, "destination" => dest} = params) do
    with {:ok, decimal_amount} <- Decimal.cast(amount) do
      {:ok, %{
        wallet_account_id: wa, rail_type: rt, amount: decimal_amount, currency: cur,
        destination: dest, initiated_by: params["initiated_by"] || "mobile_app"
      }}
    else
      _ -> {:error, "amount must be a valid decimal"}
    end
  end

  defp build_attrs(_params) do
    {:error, "wallet_account_id, rail_type, amount, currency, and destination are required"}
  end

  defp payment_json(p) do
    %{
      external_payment_id: p.id,
      rail_type: p.rail_type,
      amount: p.amount,
      currency: p.currency,
      status: p.status,
      external_reference: p.external_reference,
      failure_reason: p.failure_reason,
      submitted_at: p.submitted_at,
      completed_at: p.completed_at
    }
  end

  defp changeset_error_message(changeset) do
    changeset
    |> Ecto.Changeset.traverse_errors(fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map(fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
    |> Enum.join("; ")
  end
end
