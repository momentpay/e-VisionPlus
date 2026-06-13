defmodule VmuCore.HCS.CompanyOnboarding do
  @moduledoc """
  Corporate card programme onboarding — creates a company record and
  provisions employee cards under the parent credit pool.
  """

  alias VmuCore.HCS.{Company, EmployeeCard}
  alias VmuCore.CMS.Account
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Creates a corporate parent CMS account and the HCS Company master record.

  attrs = %{
    account_attrs: %{...}  — fields for cms_accounts
    company_attrs: %{...}  — fields for hcs_companies
  }
  """
  def onboard_company(attrs) do
    Repo.transaction(fn ->
      {:ok, parent_account} =
        %Account{}
        |> Account.changeset(Map.merge(attrs.account_attrs, %{account_type: "CORPORATE_PARENT"}))
        |> Repo.insert()

      {:ok, company} =
        %Company{}
        |> Company.changeset(Map.merge(attrs.company_attrs, %{
          parent_account_id: parent_account.id,
          available_limit:   Map.get(attrs.company_attrs, :credit_limit, D.new(0))
        }))
        |> Repo.insert()

      %{company: company, parent_account: parent_account}
    end)
  end

  @doc """
  Adds an employee card under an HCS company.
  Validates that the proposed individual_limit fits within the remaining company pool.

  card_attrs must include :individual_limit.
  employee_attrs are used to create the EMPLOYEE_CARD CMS account.
  """
  def add_employee_card(company_id, employee_attrs, card_attrs) do
    company = Repo.get!(Company, company_id)

    existing_allocated =
      from(ec in EmployeeCard,
        where: ec.company_id == ^company_id and ec.status == "ACTIVE",
        select: coalesce(sum(ec.individual_limit), 0)
      )
      |> Repo.one()
      |> Kernel.||(D.new(0))

    proposed_limit  = D.new(card_attrs.individual_limit)
    remaining_pool  = D.sub(company.credit_limit, existing_allocated)
    active_card_count = count_active_cards(company_id)

    cond do
      active_card_count >= company.max_employee_cards ->
        {:error, :max_employee_cards_reached}

      D.gt?(proposed_limit, remaining_pool) ->
        {:error, :individual_limit_exceeds_company_pool}

      true ->
        Repo.transaction(fn ->
          {:ok, employee_account} =
            %Account{}
            |> Account.changeset(Map.merge(employee_attrs, %{
              account_type: "EMPLOYEE_CARD",
              credit_limit: proposed_limit,
              open_to_buy:  proposed_limit
            }))
            |> Repo.insert()

          {:ok, card} =
            %EmployeeCard{}
            |> EmployeeCard.changeset(Map.merge(card_attrs, %{
              company_id:          company_id,
              employee_account_id: employee_account.id,
              available_individual: proposed_limit,
              individual_limit:    proposed_limit,
              status:              "ACTIVE",
              issued_at:           DateTime.utc_now()
            }))
            |> Repo.insert()

          %{employee_card: card, employee_account: employee_account}
        end)
    end
  end

  defp count_active_cards(company_id) do
    Repo.one(
      from ec in EmployeeCard,
        where: ec.company_id == ^company_id and ec.status == "ACTIVE",
        select: count(ec.id)
    ) || 0
  end
end
