defmodule VmuCore.HCS.FacilityLimitCommand do
  @moduledoc """
  Maker-checker command for HCS company facility limit changes (Way4
  parity plan Phase 1 item 2, 2026-07-25) — same shape as
  `COL.WorkoutCommand`: `request/3` parks a change, `approve/2` gates on
  the approver's role being in `hcs.facility_limit_approval_matrix` for
  the company's bank (ADMIN always qualifies) plus maker ≠ checker, then
  applies the new limit.

  Applying a limit change also adjusts `available_limit` by the same
  delta (mirrors `AccountComponent`'s `perm_limit_save` — the
  account-level equivalent for a single credit card account) — never
  resets it to the full new limit, since that would erase whatever the
  company had already drawn down.
  """

  import Ecto.Query

  alias VmuCore.{Repo, HCS.Company, HCS.FacilityLimitChange, CMS.Account}
  alias VmuCore.Shared.ModuleConfigEngine
  alias Decimal, as: D

  @doc "Request a facility limit change. Parked as PENDING_APPROVAL."
  @spec request(integer(), Decimal.t() | number(), keyword()) ::
          {:ok, FacilityLimitChange.t()} | {:error, term()}
  def request(company_id, requested_limit, opts \\ []) do
    with %Company{} = company <- Repo.get(Company, company_id) || {:error, :not_found} do
      %FacilityLimitChange{}
      |> FacilityLimitChange.changeset(%{
        company_id: company_id,
        current_limit: company.credit_limit,
        requested_limit: D.new(requested_limit),
        reason: Keyword.get(opts, :reason),
        requested_by: Keyword.fetch!(opts, :requested_by)
      })
      |> Repo.insert()
    end
  end

  @doc "Approve a PENDING_APPROVAL facility limit change and apply it."
  @spec approve(Ecto.UUID.t(), term()) ::
          {:ok, FacilityLimitChange.t()} | {:error, term()}
  def approve(change_id, %{username: _} = approver) do
    with %FacilityLimitChange{} = change <- Repo.get(FacilityLimitChange, change_id) || {:error, :not_found},
         :ok <- check_pending(change),
         :ok <- check_maker_checker(change, approver),
         :ok <- check_role_authorized(change, approver) do
      Repo.transaction(fn ->
        company = Repo.get!(Company, change.company_id)
        delta = D.sub(change.requested_limit, change.current_limit)
        new_available = D.max(D.add(company.available_limit || D.new(0), delta), D.new(0))

        {:ok, _company} =
          company
          |> Company.changeset(%{credit_limit: change.requested_limit, available_limit: new_available})
          |> Repo.update()

        {:ok, updated_change} =
          change
          |> FacilityLimitChange.changeset(%{status: "APPROVED", approved_by: approver.username})
          |> Repo.update()

        updated_change
      end)
    end
  end

  @doc "Reject a PENDING_APPROVAL facility limit change."
  @spec reject(Ecto.UUID.t(), String.t()) :: {:ok, FacilityLimitChange.t()} | {:error, term()}
  def reject(change_id, rejected_by) do
    with %FacilityLimitChange{} = change <- Repo.get(FacilityLimitChange, change_id) || {:error, :not_found},
         :ok <- check_pending(change) do
      change
      |> FacilityLimitChange.changeset(%{status: "REJECTED", approved_by: rejected_by})
      |> Repo.update()
    end
  end

  @doc "Pending facility limit changes for the approval inbox."
  @spec pending(non_neg_integer()) :: [FacilityLimitChange.t()]
  def pending(limit \\ 50) do
    Repo.all(
      from c in FacilityLimitChange,
        where: c.status == "PENDING_APPROVAL",
        order_by: [asc: c.inserted_at],
        limit: ^limit
    )
  end

  @doc "Roles currently authorized to approve facility limit changes for a company's bank."
  @spec allowed_roles(Company.t()) :: [String.t()]
  def allowed_roles(%Company{} = company) do
    {sys_id, bank_id} = company_scope(company)

    case ModuleConfigEngine.get("hcs", "facility_limit_approval_matrix", sys_id, bank_id) do
      {:ok, roles} -> roles
      {:error, _} -> []
    end
  end

  # HCS.Company doesn't carry sys_id/bank_id directly (see its schema) — it
  # scopes through the parent CMS account. Falls back to the global default
  # scope when the parent account can't be resolved.
  defp company_scope(%Company{parent_account_id: nil}), do: {"", ""}

  defp company_scope(%Company{parent_account_id: account_id}) do
    case Repo.get(Account, account_id) do
      %Account{sys_id: sys_id, bank_id: bank_id} -> {sys_id, bank_id}
      nil -> {"", ""}
    end
  end

  defp check_pending(%FacilityLimitChange{status: "PENDING_APPROVAL"}), do: :ok
  defp check_pending(%FacilityLimitChange{status: status}), do: {:error, {:not_pending, status}}

  defp check_maker_checker(%FacilityLimitChange{requested_by: maker}, %{username: checker})
       when maker == checker,
       do: {:error, :maker_cannot_approve}

  defp check_maker_checker(_, _), do: :ok

  defp check_role_authorized(_change, %{role: "ADMIN"}), do: :ok

  defp check_role_authorized(change, %{role: role}) do
    company = Repo.get!(Company, change.company_id)

    if role in allowed_roles(company) do
      :ok
    else
      {:error, {:role_not_authorized, allowed_roles(company)}}
    end
  end
end
