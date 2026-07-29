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
  alias VmuCore.CMS.{Account, DebitAccount, PrepaidAccount, PrepaidLedger, WalletProduct, WalletAccount}
  alias VmuCore.HCS.{Company, EmployeeCard, FleetCard}
  alias VmuCore.Shared.Customer

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

  @doc """
  Cross-product account rollup for the admin "All Products" list (2026-07-28)
  — one row per Arrangement enriched with live status/summary pulled from
  whichever product table actually owns it, plus the customer's name.
  Never persists status/balance onto Arrangement itself; this is a
  read-time join across up to six tables, batched per product_type (not
  N+1 per row).

  opts = %{customer_id: (optional filter), product_type: (optional
  filter), search: (optional customer name substring), limit: (default 200)}

  Returns a list of %{arrangement:, customer:, status:, summary:,
  view_ref:} maps. `view_ref` is what a "View" link should actually open
  by — the same as `account_ref` for every product except
  CORPORATE_EMPLOYEE/CORPORATE_FLEET, where it's resolved to the parent
  Company's id (HCS's admin page has no standalone employee/fleet-card
  detail view — only a company detail view with those nested inside it).
  """
  def search(opts \\ %{}) do
    customer_id  = Map.get(opts, :customer_id)
    product_type = Map.get(opts, :product_type, "")
    search_term  = Map.get(opts, :search, "")
    limit        = Map.get(opts, :limit, 200)

    query = from a in Arrangement, order_by: [desc: a.inserted_at], limit: ^limit

    query =
      if customer_id, do: where(query, [a], a.customer_id == ^customer_id), else: query

    query =
      if product_type != "", do: where(query, [a], a.product_type == ^product_type), else: query

    query =
      if search_term != "" and search_term != nil do
        cust_ids =
          Repo.all(
            from c in Customer,
              where: ilike(c.first_name, ^"%#{search_term}%") or ilike(c.last_name, ^"%#{search_term}%"),
              select: c.customer_id
          )
        where(query, [a], a.customer_id in ^cust_ids)
      else
        query
      end

    arrangements = Repo.all(query)

    customer_ids = arrangements |> Enum.map(& &1.customer_id) |> Enum.uniq()
    customers =
      if customer_ids == [] do
        %{}
      else
        Repo.all(from c in Customer, where: c.customer_id in ^customer_ids) |> Map.new(&{&1.customer_id, &1})
      end

    enrichment = enrich_by_product_type(arrangements)

    Enum.map(arrangements, fn arr ->
      key = {arr.product_type, arr.account_ref}
      %{
        arrangement: arr,
        customer:    Map.get(customers, arr.customer_id),
        status:      get_in(enrichment, [key, :status]),
        summary:     get_in(enrichment, [key, :summary]),
        view_ref:    get_in(enrichment, [key, :view_ref]) || arr.account_ref
      }
    end)
  end

  # Keyed by {product_type, account_ref} — account_ref is only guaranteed
  # unique within a product_type (the DB's own unique index shape), not
  # globally across product tables.
  defp enrich_by_product_type(arrangements) do
    arrangements
    |> Enum.group_by(& &1.product_type)
    |> Enum.flat_map(fn {type, group} -> enrich_group(type, Enum.map(group, & &1.account_ref)) end)
    |> Map.new()
  end

  defp enrich_group("CREDIT", refs) do
    Repo.all(from a in Account, where: a.account_id in ^refs,
      select: {a.account_id, a.account_status, a.credit_limit, a.open_to_buy})
    |> Enum.map(fn {id, status, limit, otb} ->
      {{"CREDIT", id}, %{status: status, summary: "Limit #{money(limit)} / OTB #{money(otb)}", view_ref: id}}
    end)
  end

  defp enrich_group("DEBIT", refs) do
    Repo.all(from a in DebitAccount, where: a.debit_account_id in ^refs,
      select: {a.debit_account_id, a.status, a.available_balance, a.currency})
    |> Enum.map(fn {id, status, bal, ccy} ->
      {{"DEBIT", id}, %{status: status, summary: "#{money(bal)} #{ccy}", view_ref: id}}
    end)
  end

  defp enrich_group("PREPAID", refs) do
    Repo.all(from a in PrepaidAccount, where: a.prepaid_account_id in ^refs,
      select: {a.prepaid_account_id, a.status, a.currency})
    |> Enum.map(fn {id, status, ccy} ->
      {{"PREPAID", id}, %{status: status, summary: "#{money(PrepaidLedger.balance(id))} #{ccy}", view_ref: id}}
    end)
  end

  defp enrich_group("CORPORATE_FACILITY", refs) do
    Repo.all(from c in Company, where: c.id in ^to_ints(refs),
      select: {c.id, c.status, c.credit_limit, c.available_limit})
    |> Enum.map(fn {id, status, limit, avail} ->
      {{"CORPORATE_FACILITY", to_string(id)},
       %{status: status, summary: "Limit #{money(limit)} / Avail #{money(avail)}", view_ref: to_string(id)}}
    end)
  end

  # HCS's admin page has no standalone employee-card detail view — only a
  # company detail view with employee cards nested inside it — so
  # view_ref resolves to the parent company's id, not the card's own id.
  defp enrich_group("CORPORATE_EMPLOYEE", refs) do
    Repo.all(from c in EmployeeCard, where: c.id in ^to_ints(refs),
      select: {c.id, c.company_id, c.status, c.individual_limit, c.available_individual})
    |> Enum.map(fn {id, company_id, status, limit, avail} ->
      {{"CORPORATE_EMPLOYEE", to_string(id)},
       %{status: status, summary: "Limit #{money(limit)} / Avail #{money(avail)}", view_ref: to_string(company_id)}}
    end)
  end

  defp enrich_group("CORPORATE_FLEET", refs) do
    Repo.all(from c in FleetCard, where: c.id in ^to_ints(refs),
      select: {c.id, c.company_id, c.status, c.individual_limit, c.available_individual})
    |> Enum.map(fn {id, company_id, status, limit, avail} ->
      {{"CORPORATE_FLEET", to_string(id)},
       %{status: status, summary: "Limit #{money(limit)} / Avail #{money(avail)}", view_ref: to_string(company_id)}}
    end)
  end

  # Digital Wallet Phase W4 (2026-07-28) — account_ref here is the
  # `wallet_product_id` (a product may hold N single-currency accounts,
  # see CMS.WalletProduct's own moduledoc), so the summary shows the
  # earliest-opened account's balance/currency as the representative
  # one, not a meaningless cross-currency sum. One batched query for
  # all accounts across every product in `refs`, not N+1 — `Map.put_new/3`
  # inside the reduce keeps only the first (earliest `inserted_at`) row
  # per product since `order_by` runs before the reduce sees the rows.
  defp enrich_group("WALLET", refs) do
    statuses =
      Repo.all(from p in WalletProduct, where: p.wallet_product_id in ^refs,
        select: {p.wallet_product_id, p.status})
      |> Map.new()

    primary_accounts =
      Repo.all(from a in WalletAccount, where: a.wallet_product_id in ^refs,
        order_by: [asc: a.inserted_at], select: {a.wallet_product_id, a.available_balance, a.currency})
      |> Enum.reduce(%{}, fn {product_id, bal, ccy}, acc -> Map.put_new(acc, product_id, {bal, ccy}) end)

    Enum.map(statuses, fn {product_id, status} ->
      summary =
        case Map.get(primary_accounts, product_id) do
          {bal, ccy} -> "#{money(bal)} #{ccy}"
          nil -> "No accounts"
        end

      {{"WALLET", product_id}, %{status: status, summary: summary, view_ref: product_id}}
    end)
  end

  defp enrich_group(_type, _refs), do: []

  defp to_ints(refs) do
    refs
    |> Enum.map(fn r -> case Integer.parse(r) do {n, ""} -> n; _ -> nil end end)
    |> Enum.reject(&is_nil/1)
  end

  defp money(nil), do: "0.00"
  defp money(%Decimal{} = d), do: d |> Decimal.round(2) |> Decimal.to_string()
  defp money(v), do: to_string(v)
end
