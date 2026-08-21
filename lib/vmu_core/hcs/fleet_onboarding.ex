defmodule VmuCore.HCS.FleetOnboarding do
  @moduledoc """
  Vehicle onboarding + fleet card issuance under an HCS company facility
  (Way4 parity plan Phase 1 item 3, 2026-07-25).

  Fleet card accounts reuse the company's own parent `CMS.Account`'s
  `customer_id` — a vehicle isn't a separate KYC/legal entity, it's still
  an asset of the same corporate customer, exactly like an employee card
  account belongs to the company's corporate identity rather than a new
  customer per card.
  """

  alias VmuCore.{Repo, HCS.Company, HCS.Vehicle, HCS.FleetCard, HCS.EmployeeCard, CMS.Account, CMS.Arrangements}
  import Ecto.Query
  alias Decimal, as: D

  def add_vehicle(company_id, attrs) do
    %Vehicle{}
    |> Vehicle.changeset(Map.put(attrs, :company_id, company_id))
    |> Repo.insert()
  end

  @doc """
  Issues a fleet card for a vehicle. Validates the proposed
  individual_limit fits within the remaining company pool — unlike
  `CompanyOnboarding.add_employee_card/3`'s equivalent check (which only
  sums existing employee cards), this sums **both** employee and fleet
  card allocations, since they draw from the same `Company.credit_limit`
  pool. Note: this is a card-issuance-time sanity check only — the real
  security boundary is `LimitController.check_company_pool/2` at
  authorization time, which always uses the true `available_limit`
  regardless of card kind and is already correct.
  """
  def add_fleet_card(company_id, vehicle_id, card_attrs) do
    company = Repo.get!(Company, company_id)
    vehicle = Repo.get!(Vehicle, vehicle_id)

    cond do
      vehicle.status != "ACTIVE" ->
        {:error, :vehicle_not_active}

      true ->
        existing_allocated = allocated_pool(company_id)
        proposed_limit = D.new(card_attrs.individual_limit)
        remaining_pool = D.sub(company.credit_limit, existing_allocated)

        if D.gt?(proposed_limit, remaining_pool) do
          {:error, :individual_limit_exceeds_company_pool}
        else
          parent_account = Repo.get!(Account, company.parent_account_id)

          Repo.transaction(fn ->
            {:ok, account} =
              %Account{}
              |> Account.changeset(%{
                customer_id: parent_account.customer_id,
                sys_id: parent_account.sys_id, bank_id: parent_account.bank_id,
                logo_id: parent_account.logo_id, block_id: parent_account.block_id,
                pan_token: synthetic_pan_token(vehicle), last_four: "0000", expiry_date: "0000",
                credit_limit: proposed_limit, open_to_buy: proposed_limit
              })
              |> Repo.insert()

            {:ok, card} =
              %FleetCard{}
              |> FleetCard.changeset(Map.merge(card_attrs, %{
                company_id: company_id, vehicle_id: vehicle_id, account_id: account.account_id,
                available_individual: proposed_limit, individual_limit: proposed_limit,
                status: "ACTIVE", issued_at: DateTime.utc_now() |> DateTime.truncate(:second)
              }))
              |> Repo.insert()

            # Koṣa domain-model alignment (2026-07-28) — account_ref is
            # the FleetCard's own id (carries company_id); customer_id
            # is the company's own identity, same as the account it was
            # just synthesized from (a vehicle isn't a separate legal
            # entity — see the moduledoc above).
            {:ok, _arrangement} =
              Arrangements.record(%{
                customer_id: account.customer_id, product_type: "CORPORATE_FLEET",
                account_ref: to_string(card.id), opened_at: Date.utc_today()
              })

            %{fleet_card: card, account: account}
          end)
        end
    end
  end

  defp allocated_pool(company_id) do
    employee_sum =
      from(ec in EmployeeCard, where: ec.company_id == ^company_id and ec.status == "ACTIVE",
        select: coalesce(sum(ec.individual_limit), 0))
      |> Repo.one() |> Kernel.||(D.new(0))

    fleet_sum =
      from(fc in FleetCard, where: fc.company_id == ^company_id and fc.status == "ACTIVE",
        select: coalesce(sum(fc.individual_limit), 0))
      |> Repo.one() |> Kernel.||(D.new(0))

    D.add(employee_sum, fleet_sum)
  end

  defp synthetic_pan_token(vehicle) do
    :crypto.hash(:sha256, "hcs-fleet-#{vehicle.id}-#{System.unique_integer([:positive])}")
    |> Base.encode16(case: :lower)
  end
end
