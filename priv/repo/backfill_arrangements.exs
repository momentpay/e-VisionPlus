# Koṣa domain-model alignment (2026-07-28) — CMS.Arrangement is only
# recorded by the live call sites added that day (AccountComponent's
# wizard, DebitAccountOpening.open/1, PrepaidAccountOpening.open/1,
# HCS.CompanyOnboarding/FleetOnboarding). Every account created before
# then — including every seeds.exs customer, which inserts straight into
# tables via Repo.insert_all and never goes through those call sites —
# has no Arrangement row at all, so it's invisible on the Customer/
# Accounts "All Products" views even though the underlying account is
# real. This backfills one Arrangement per pre-existing account across
# all six sources.
#
#   mix run priv/repo/backfill_arrangements.exs
#
# Idempotent: skips any (product_type, account_ref) pair that already
# has an Arrangement (same uniqueness the DB itself enforces).

import Ecto.Query
alias VmuCore.Repo
alias VmuCore.CMS.{Account, Arrangement, DebitAccount, PrepaidAccount}
alias VmuCore.HCS.{Company, EmployeeCard, FleetCard}

existing =
  Repo.all(from a in Arrangement, select: {a.product_type, a.account_ref})
  |> MapSet.new()

today = Date.utc_today()
now   = DateTime.utc_now() |> DateTime.truncate(:second)

insert_row = fn product_type, account_ref, customer_id, opened_at ->
  Repo.insert_all("cms_arrangements", [
    %{
      id: Ecto.UUID.dump!(Ecto.UUID.generate()),
      customer_id: Ecto.UUID.dump!(customer_id),
      product_type: product_type,
      account_ref: account_ref,
      opened_at: opened_at || today,
      inserted_at: now |> DateTime.to_naive(),
      updated_at: now |> DateTime.to_naive()
    }
  ], on_conflict: :nothing)
end

backfill = fn label, product_type, rows, key_fn ->
  {created, skipped} =
    Enum.reduce(rows, {0, 0}, fn row, {c, s} ->
      {account_ref, customer_id, opened_at} = key_fn.(row)

      cond do
        is_nil(customer_id) ->
          {c, s + 1}

        MapSet.member?(existing, {product_type, account_ref}) ->
          {c, s + 1}

        true ->
          insert_row.(product_type, account_ref, customer_id, opened_at)
          {c + 1, s}
      end
    end)

  IO.puts("  #{label}: created=#{created} skipped=#{skipped} (of #{length(rows)})")
end

IO.puts("==> Backfilling CMS.Arrangement for pre-existing accounts...")

backfill.(
  "CREDIT (cms_accounts)", "CREDIT",
  Repo.all(from a in Account, select: %{id: a.account_id, customer_id: a.customer_id, opened_at: a.open_date}),
  fn a -> {a.id, a.customer_id, a.opened_at} end
)

backfill.(
  "DEBIT (cms_debit_accounts)", "DEBIT",
  Repo.all(from a in DebitAccount, select: %{id: a.debit_account_id, customer_id: a.customer_id, opened_at: a.opened_at}),
  fn a -> {a.id, a.customer_id, a.opened_at} end
)

backfill.(
  "PREPAID (cms_prepaid_accounts)", "PREPAID",
  Repo.all(from a in PrepaidAccount, select: %{id: a.prepaid_account_id, customer_id: a.customer_id, opened_at: a.opened_at}),
  fn a -> {a.id, a.customer_id, a.opened_at} end
)

# Company/EmployeeCard/FleetCard have no customer_id of their own — same
# "point through the parent CMS.Account" resolution CompanyOnboarding/
# FleetOnboarding already use at creation time.
companies_by_id =
  Repo.all(from c in Company, select: {c.id, c.parent_account_id}) |> Map.new()

account_customer_by_id =
  Repo.all(from a in Account, select: {a.account_id, a.customer_id}) |> Map.new()

backfill.(
  "CORPORATE_FACILITY (hcs_companies)", "CORPORATE_FACILITY",
  Repo.all(from c in Company, select: %{id: c.id, parent_account_id: c.parent_account_id}),
  fn c -> {to_string(c.id), Map.get(account_customer_by_id, c.parent_account_id), nil} end
)

backfill.(
  "CORPORATE_EMPLOYEE (hcs_employee_cards)", "CORPORATE_EMPLOYEE",
  Repo.all(from c in EmployeeCard, select: %{id: c.id, employee_account_id: c.employee_account_id}),
  fn c -> {to_string(c.id), Map.get(account_customer_by_id, c.employee_account_id), nil} end
)

backfill.(
  "CORPORATE_FLEET (hcs_fleet_cards)", "CORPORATE_FLEET",
  Repo.all(from c in FleetCard, select: %{id: c.id, company_id: c.company_id}),
  fn c ->
    customer_id =
      case Map.get(companies_by_id, c.company_id) do
        nil -> nil
        parent_account_id -> Map.get(account_customer_by_id, parent_account_id)
      end

    {to_string(c.id), customer_id, nil}
  end
)

IO.puts("==> Arrangement backfill complete.")
