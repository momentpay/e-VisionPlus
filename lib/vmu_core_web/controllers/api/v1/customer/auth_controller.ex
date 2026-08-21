defmodule VmuCoreWeb.Api.V1.Customer.AuthController do
  @moduledoc """
  Cardholder login — CAM Phase F1 (2026-08-02). Sits under plain
  `:api_v1` (`ApiV1Auth`, proving "this is Kosa app") rather than
  `:api_v1_cardholder` — there's no cardholder token to check yet, that's
  what this controller issues.
  """

  use Phoenix.Controller, formats: [:json]

  alias VmuCore.CAM.Auth
  alias VmuCoreWeb.Plugs.ApiV1Auth
  alias VmuCoreWeb.Api.V1.ErrorEnvelope

  @doc "POST /api/v1/customer/auth/request_otp"
  def request_otp(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "nts:customer")

    if conn.halted do
      conn
    else
      with {:ok, sys_id, bank_id, mobile_number} <- required_mobile_params(params) do
        :ok = Auth.request_otp(sys_id, bank_id, mobile_number)
        json(conn, ErrorEnvelope.ok(%{message: "If this number is registered, a code has been sent."}))
      else
        {:error, message} -> ErrorEnvelope.send(conn, 422, "missing_params", message)
      end
    end
  end

  @doc "POST /api/v1/customer/auth/verify_otp"
  def verify_otp(conn, params) do
    conn = ApiV1Auth.require_scope(conn, "nts:customer")

    if conn.halted do
      conn
    else
      with {:ok, sys_id, bank_id, mobile_number} <- required_mobile_params(params),
           %{"code" => code} when is_binary(code) and code != "" <- params do
        case Auth.verify_otp(sys_id, bank_id, mobile_number, code) do
          {:ok, token, customer} ->
            json(conn, ErrorEnvelope.ok(%{
              customer_token: token,
              customer: %{customer_id: customer.customer_id, first_name: customer.first_name, last_name: customer.last_name}
            }))

          {:error, :not_found} -> ErrorEnvelope.send(conn, 401, "invalid_credentials", "No matching login attempt")
          {:error, :invalid_code} -> ErrorEnvelope.send(conn, 401, "invalid_code", "Incorrect code")
          {:error, :expired} -> ErrorEnvelope.send(conn, 401, "code_expired", "This code has expired — request a new one")
          {:error, :too_many_attempts} -> ErrorEnvelope.send(conn, 429, "too_many_attempts", "Too many incorrect attempts — request a new code")
        end
      else
        {:error, message} -> ErrorEnvelope.send(conn, 422, "missing_params", message)
        _ -> ErrorEnvelope.send(conn, 422, "missing_params", "code is required")
      end
    end
  end

  defp required_mobile_params(%{"sys_id" => sys_id, "bank_id" => bank_id, "mobile_number" => mobile_number})
       when is_binary(sys_id) and is_binary(bank_id) and is_binary(mobile_number) and mobile_number != "" do
    {:ok, sys_id, bank_id, mobile_number}
  end

  defp required_mobile_params(_params) do
    {:error, "sys_id, bank_id, and mobile_number are required"}
  end
end
