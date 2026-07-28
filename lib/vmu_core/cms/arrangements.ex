defmodule VmuCore.CMS.Arrangements do
  @moduledoc """
  Context for `CMS.Arrangement` (Koṣa domain-model alignment,
  2026-07-28). `record/1` is called once, alongside each product's own
  account-opening call, from every real creation point in the codebase:
  `AccountComponent`'s credit wizard, `DebitAccountOpening.open/1`,
  `PrepaidAccountOpening.open/1`, `HCS.CompanyOnboarding.
  onboard_company/1`/`add_employee_card/3`, `HCS.FleetOnboarding.
  add_fleet_card/3`.
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.Arrangement}

  @doc """
  attrs = %{customer_id:, product_type:, account_ref:, opened_at: (optional, default today)}
  """
  def record(attrs) do
    %Arrangement{}
    |> Arrangement.changeset(Map.put_new(attrs, :opened_at, Date.utc_today()))
    |> Repo.insert()
  end

  @doc "Every arrangement for a customer, newest first — the real cross-product index."
  @spec list_for_customer(Ecto.UUID.t()) :: [Arrangement.t()]
  def list_for_customer(customer_id) do
    Repo.all(
      from a in Arrangement,
        where: a.customer_id == ^customer_id,
        order_by: [desc: a.inserted_at]
    )
  end
end
