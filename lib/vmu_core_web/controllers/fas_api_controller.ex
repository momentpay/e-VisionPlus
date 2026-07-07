defmodule VmuCoreWeb.FasApiController do
  @moduledoc """
  Internal JSON API for settlement_core's cross-system integration (FAS-P4).

  Routes (under /api/fas):
    GET  /auth/lookup              — verify a dump record's approval_code against fas_authorizations
    POST /settlement/confirm       — post ledger + clear hold for a batch of settled auths

  Authentication: shared secret via `x-vmu-api-key` header, configured in
  `config :vmu_core, :internal_api_key`.  This API is not public — only
  settlement_core should be calling it.
  """

  use Phoenix.Controller, formats: [:json]

  alias VmuCore.FAS.{AuthLookup, SettlementPostingAdapter}

  # ---------------------------------------------------------------------------
  # Auth lookup (4A / 4B support)
  # ---------------------------------------------------------------------------

  @doc """
  GET /api/fas/auth/lookup?rrn=:rrn&approval_code=:approval_code

  Verifies that the dump record's approval_code matches the issued authorization.
  settlement_core calls this after match_records to detect approval_code mismatches
  that warrant exception type 5.5.

  Response 200:
    %{result: "match"}
    %{result: "mismatch", vmu_approval_code: "123456"}
    %{result: "not_found"}
  """
  def auth_lookup(conn, %{"rrn" => rrn, "approval_code" => approval_code}) do
    case AuthLookup.verify(rrn, approval_code) do
      :match ->
        json(conn, %{result: "match"})

      {:mismatch, actual} ->
        json(conn, %{result: "mismatch", vmu_approval_code: actual})

      :not_found ->
        json(conn, %{result: "not_found"})
    end
  end

  def auth_lookup(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "rrn and approval_code are required"})
  end

  # ---------------------------------------------------------------------------
  # Settlement confirm (4C + 4D)
  # ---------------------------------------------------------------------------

  @doc """
  POST /api/fas/settlement/confirm

  Body: JSON array of settlement confirmations.
  Each item:
    {
      "approval_code": "123456",
      "rrn":           "000000123456",
      "settled_amount": "150.00",
      "settled_date":   "2026-07-02"
    }

  For each item, if the approval_code+rrn matches a fas_authorization:
    - Posts a PURCHASE LedgerEntry (idempotent)
    - Sets fas_pending_holds.cleared_at

  Response 200:
    %{confirmed: n, not_found: n, errors: n}
  """
  def settlement_confirm(conn, %{"items" => items}) when is_list(items) do
    parsed = Enum.map(items, &parse_settlement_item/1)

    invalid = Enum.filter(parsed, &match?({:error, _}, &1))

    if invalid != [] do
      conn
      |> put_status(:bad_request)
      |> json(%{error: "invalid items", count: length(invalid)})
    else
      batch = Enum.map(parsed, fn {:ok, item} -> item end)
      result = SettlementPostingAdapter.confirm_batch(batch)
      json(conn, result)
    end
  end

  def settlement_confirm(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "body must be {\"items\": [...]}"})
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  defp parse_settlement_item(%{
    "approval_code"  => ac,
    "rrn"            => rrn,
    "settled_amount" => amount_str,
    "settled_date"   => date_str
  }) do
    with {:ok, amount} <- parse_decimal(amount_str),
         {:ok, date}   <- Date.from_iso8601(date_str) do
      {:ok, %{
        approval_code:  ac,
        rrn:            rrn,
        settled_amount: amount,
        settled_date:   date
      }}
    end
  end

  defp parse_settlement_item(_), do: {:error, :invalid_shape}

  defp parse_decimal(str) when is_binary(str) do
    case Decimal.parse(str) do
      {d, ""} -> {:ok, d}
      _       -> {:error, :invalid_decimal}
    end
  end

  defp parse_decimal(%Decimal{} = d), do: {:ok, d}
  defp parse_decimal(_), do: {:error, :invalid_decimal}
end
