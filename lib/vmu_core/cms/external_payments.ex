defmodule VmuCore.CMS.ExternalPayments do
  @moduledoc """
  Read-side context for `CMS.ExternalPayment` — Digital Wallet Phase W6
  (2026-07-29). Initiation itself is `CMS.ExternalPaymentCommand`, not
  here — this module is lookups only.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.CMS.ExternalPayment

  @spec get(binary()) :: ExternalPayment.t() | nil
  def get(id), do: Repo.get(ExternalPayment, id)

  @doc "List payments, optionally filtered by wallet_account_id/customer_id/status."
  @spec list(map()) :: [ExternalPayment.t()]
  def list(filters \\ %{}) do
    ExternalPayment
    |> maybe_filter(:wallet_account_id, Map.get(filters, "wallet_account_id"))
    |> maybe_filter(:customer_id, Map.get(filters, "customer_id"))
    |> maybe_filter(:status, Map.get(filters, "status"))
    |> order_by([p], desc: p.inserted_at)
    |> Repo.all()
  end

  defp maybe_filter(query, _field, nil), do: query
  defp maybe_filter(query, _field, ""), do: query
  defp maybe_filter(query, field, value), do: where(query, [p], field(p, ^field) == ^value)
end
