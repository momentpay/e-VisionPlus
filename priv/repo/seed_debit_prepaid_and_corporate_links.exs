# Koṣa domain-model alignment (2026-07-28), follow-up — seeds.exs never
# had a Debit or Prepaid phase at all, and its HCS phase (Phase 7)
# raw-inserted both companies with parent_account_id left NULL, so
# neither company was ever actually linked to its owning customer at the
# DB level (found live: "Zaabi Group LLC" has no link to Abdullah Al
# Zaabi even though the company name/email domain/employee records all
# point at him). This script:
#
#   1. Patches both existing hcs_companies rows to point at their real
#      owning customer's existing CMS.Account (Abdullah Al Zaabi /
#      Mohammad Al Farsi — both already seeded in Phase 2), then records
#      the CORPORATE_FACILITY Arrangement that was missing as a result.
#   2. Opens Debit accounts (funded, with an activated card) for 3
#      customers and Prepaid accounts (loaded, with an activated card)
#      for 3 more, via the real DebitAccountOpening/PrepaidAccountOpening/
#      CardLifecycle context functions — so Arrangement recording,
#      GL posting, and card issuance all happen exactly as they would
#      from the admin UI, not hand-rolled.
#
#   mix run priv/repo/seed_debit_prepaid_and_corporate_links.exs
#
# Idempotent: skips any customer that already has a Debit/Prepaid
# account, and skips the company patch if parent_account_id is already set.

import Ecto.Query
alias VmuCore.Repo
alias VmuCore.Shared.Customer
alias VmuCore.CMS.{Account, Arrangements, DebitAccount, DebitAccountOpening, PrepaidAccount, PrepaidAccountOpening, DebitFundingCommand, PrepaidLedger}
alias VmuCore.HCS.Company
alias VmuCore.CTA.CardLifecycle

find_customer = fn email -> Repo.get_by!(Customer, email: email) end
find_account_for = fn customer_id -> Repo.one!(from a in Account, where: a.customer_id == ^customer_id, limit: 1) end

IO.puts("==> Linking HCS companies to their real owning customer...")

link_company = fn company_code, owner_email ->
  company  = Repo.get_by!(Company, company_code: company_code)
  customer = find_customer.(owner_email)
  account  = find_account_for.(customer.customer_id)

  if is_nil(company.parent_account_id) do
    {1, _} =
      Repo.update_all(from(c in Company, where: c.id == ^company.id),
        set: [parent_account_id: account.account_id])
    IO.puts("  #{company_code} -> parent_account_id set (owner: #{customer.first_name} #{customer.last_name})")
  else
    IO.puts("  #{company_code}: already linked, skipped")
  end

  case Arrangements.record(%{
    customer_id: customer.customer_id, product_type: "CORPORATE_FACILITY",
    account_ref: to_string(company.id)
  }) do
    {:ok, _}        -> IO.puts("  #{company_code}: CORPORATE_FACILITY arrangement recorded")
    {:error, _cs}   -> IO.puts("  #{company_code}: arrangement already present, skipped")
  end
end

link_company.("ZAABI", "cfo@zaabi-group.ae")
link_company.("AFTR",  "m.alfarsi@alfarsitrading.ae")

IO.puts("==> Seeding Debit accounts (funded + activated card)...")

open_debit = fn email, amount ->
  customer = find_customer.(email)

  if Repo.exists?(from d in DebitAccount, where: d.customer_id == ^customer.customer_id) do
    IO.puts("  #{email}: already has a Debit account, skipped")
  else
    {:ok, account} =
      DebitAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: "MMPD", bank_id: "MMBD",
        logo_id: "MMST", block_id: "MMBC"
      })

    {:ok, card} =
      CardLifecycle.issue_new_debit(account, card_type: "PRIMARY",
        emboss_name: "#{customer.first_name} #{customer.last_name}" |> String.upcase(), activate: true)

    {:ok, _funding} =
      DebitFundingCommand.fund(%{
        debit_account_id: account.debit_account_id, amount: Decimal.new(amount),
        channel: "ADMIN_MANUAL", posted_by: "SEED"
      })

    IO.puts("  #{email}: Debit account opened, card #{card.card_id |> to_string() |> String.slice(0, 8)} issued+activated, funded #{amount}")
  end
end

open_debit.("ahmed.alrashid@email.ae",   "8500.00")
open_debit.("sara.almansouri@email.ae",  "3200.00")
open_debit.("cfo@zaabi-group.ae",        "45000.00")

IO.puts("==> Seeding Prepaid accounts (loaded + activated card)...")

open_prepaid = fn email, amount ->
  customer = find_customer.(email)

  if Repo.exists?(from p in PrepaidAccount, where: p.customer_id == ^customer.customer_id) do
    IO.puts("  #{email}: already has a Prepaid account, skipped")
  else
    {:ok, account} =
      PrepaidAccountOpening.open(%{
        customer_id: customer.customer_id, sys_id: "MMPD", bank_id: "MMBD",
        logo_id: "MMST", block_id: "MMBC"
      })

    {:ok, card} =
      CardLifecycle.issue_new_prepaid(account, card_type: "PRIMARY",
        emboss_name: "#{customer.first_name} #{customer.last_name}" |> String.upcase(), activate: true)

    {:ok, _load} =
      PrepaidLedger.load(%{
        prepaid_account_id: account.prepaid_account_id, amount: Decimal.new(amount),
        channel: "ADMIN_MANUAL", posted_by: "SEED"
      })

    IO.puts("  #{email}: Prepaid account opened, card #{card.card_id |> to_string() |> String.slice(0, 8)} issued+activated, loaded #{amount}")
  end
end

open_prepaid.("priya.sharma@email.com",           "1500.00")
open_prepaid.("khalid.alshamsi@shamsi.ae",         "2500.00")
open_prepaid.("fatima.alkhoori@zaabi-group.ae",    "800.00")

IO.puts("==> Done.")
