defmodule VmuCore.Kyc.StatusSync do
  @moduledoc """
  The real integration point (`docs/kyc/KYC_Implementation_Tracker.md` §5):
  on approval/rejection, syncs the pre-existing flat `kyc_status`/
  `kyc_verified_at` fields that already live on five different schemas
  (`Shared.Customer`, `CMS.DebitAccount`, `CMS.PrepaidAccount`,
  `CMS.WalletAccount`, `HCS.Company`) — each set today by its own product's
  "KYC Verify/Reject/Reset" quick-action button with no shared mechanism
  behind it. This module makes `Kyc.Request` the system of record without
  rewriting those four already-working admin screens.

  Corrected from the tracker doc's first-draft table after checking the
  real schemas: `CORPORATE_EMPLOYEE` KYC is a *person* (an employee is a
  `Shared.Customer` row, no `kyc_status` field exists on `EmployeeCard`
  itself), so it syncs `Customer`, not `Company`. `CORPORATE_FACILITY` and
  `CORPORATE_FLEET` are company-level (`Arrangement.account_ref` resolves
  to `Company.id` directly for FACILITY, or to `FleetCard.id` -> `company_id`
  for FLEET) — both sync `HCS.Company`.

  If the target row can't be resolved (no account/company opened yet, or no
  `arrangement_id` set on the request), sync is skipped, not an error — the
  `kyc_requests` row itself remains the record of truth regardless.
  """

  import Ecto.Query

  alias VmuCore.Repo
  alias VmuCore.Kyc.Request
  alias VmuCore.Shared.Customer
  alias VmuCore.CMS.{DebitAccount, PrepaidAccount, WalletAccount, Arrangement}
  alias VmuCore.HCS.{Company, FleetCard}

  @doc "Sync the relevant product row's kyc_status for an approved/rejected request."
  @spec sync(Request.t()) :: :ok | :skipped
  def sync(%Request{status: "approved"} = request) do
    do_sync(request, "VERIFIED", true)
  end

  def sync(%Request{status: "rejected"} = request) do
    do_sync(request, "REJECTED", false)
  end

  def sync(%Request{}), do: :skipped

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp do_sync(%Request{product_type: pt} = req, status, verified?) when pt in ~w[CREDIT CORPORATE_EMPLOYEE] do
    sync_row(Repo.get(Customer, req.customer_id), status, verified?)
  end

  defp do_sync(%Request{product_type: "DEBIT"} = req, status, verified?) do
    sync_latest_account(DebitAccount, req.customer_id, status, verified?)
  end

  defp do_sync(%Request{product_type: "PREPAID"} = req, status, verified?) do
    sync_latest_account(PrepaidAccount, req.customer_id, status, verified?)
  end

  defp do_sync(%Request{product_type: "WALLET"} = req, status, verified?) do
    sync_latest_account(WalletAccount, req.customer_id, status, verified?)
  end

  defp do_sync(%Request{product_type: "CORPORATE_FACILITY"} = req, status, verified?) do
    with account_ref when not is_nil(account_ref) <- resolve_account_ref(req.arrangement_id),
         {company_id, ""} <- Integer.parse(account_ref) do
      sync_row(Repo.get(Company, company_id), status, verified?)
    else
      _ -> :skipped
    end
  end

  defp do_sync(%Request{product_type: "CORPORATE_FLEET"} = req, status, verified?) do
    with account_ref when not is_nil(account_ref) <- resolve_account_ref(req.arrangement_id),
         {fleet_card_id, ""} <- Integer.parse(account_ref),
         %FleetCard{company_id: company_id} <- Repo.get(FleetCard, fleet_card_id) do
      sync_row(Repo.get(Company, company_id), status, verified?)
    else
      _ -> :skipped
    end
  end

  defp do_sync(%Request{}, _status, _verified?), do: :skipped

  defp resolve_account_ref(nil), do: nil
  defp resolve_account_ref(arrangement_id) do
    case Repo.get(Arrangement, arrangement_id) do
      nil -> nil
      arrangement -> arrangement.account_ref
    end
  end

  defp sync_latest_account(schema, customer_id, status, verified?) do
    query =
      from a in schema,
        where: a.customer_id == ^customer_id,
        order_by: [desc: a.inserted_at],
        limit: 1

    sync_row(Repo.one(query), status, verified?)
  end

  defp sync_row(nil, _status, _verified?), do: :skipped

  # HCS.Company.kyc_verified_at is :utc_datetime; every other target
  # (Customer/DebitAccount/PrepaidAccount/WalletAccount) is :naive_datetime.
  # Ecto.Changeset.change/2 bypasses casting, so the value has to already be
  # the right type per target -- one more piece of the "five independent,
  # never-reconciled flags" state this module is closing over (see moduledoc).
  defp sync_row(%Company{} = row, status, verified?) do
    verified_at = if verified?, do: DateTime.utc_now() |> DateTime.truncate(:second), else: nil

    row
    |> Ecto.Changeset.change(kyc_status: status, kyc_verified_at: verified_at)
    |> Repo.update!()

    :ok
  end

  defp sync_row(row, status, verified?) do
    verified_at = if verified?, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second), else: nil

    row
    |> Ecto.Changeset.change(kyc_status: status, kyc_verified_at: verified_at)
    |> Repo.update!()

    :ok
  end
end
