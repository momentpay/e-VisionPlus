defmodule VmuCore.HCS.CompanyOnboarding do
  @moduledoc """
  Corporate card programme onboarding — creates a company record and
  provisions employee cards under the parent credit pool.
  """

  alias VmuCore.HCS.{Company, EmployeeCard}
  alias VmuCore.CMS.{Account, Arrangements}
  alias VmuCore.Repo
  import Ecto.Query
  alias Decimal, as: D

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
          # Found live 2026-07-25 (Way4 parity plan Phase 1 item 2): this
          # referenced parent_account.id, but CMS.Account's real primary
          # key field is account_id — onboard_company/1 has never
          # actually succeeded until this fix.
          parent_account_id: parent_account.account_id,
          available_limit:   Map.get(attrs.company_attrs, :credit_limit, D.new(0))
        }))
        |> Repo.insert()

      # Koṣa domain-model alignment (2026-07-28) — account_ref is the
      # Company's own id, not the parent CMS.Account: HcsComponent's
      # detail view is loaded by company id, so that's what a customer's
      # arrangement list needs to click through to the right screen.
      {:ok, _arrangement} =
        Arrangements.record(%{
          customer_id: parent_account.customer_id, product_type: "CORPORATE_FACILITY",
          account_ref: to_string(company.id), opened_at: Date.utc_today()
        })

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
              # Same account_id (not id) fix as onboard_company/1 above.
              employee_account_id: employee_account.account_id,
              available_individual: proposed_limit,
              individual_limit:    proposed_limit,
              status:              "ACTIVE",
              issued_at:           DateTime.utc_now()
            }))
            |> Repo.insert()

          # Koṣa domain-model alignment (2026-07-28) — account_ref is the
          # EmployeeCard's own id (carries company_id), not the
          # underlying CMS.Account — same "point at whatever an operator
          # actually needs to click through to" reasoning as
          # onboard_company/1 above.
          {:ok, _arrangement} =
            Arrangements.record(%{
              customer_id: employee_account.customer_id, product_type: "CORPORATE_EMPLOYEE",
              account_ref: to_string(card.id), opened_at: Date.utc_today()
            })

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
