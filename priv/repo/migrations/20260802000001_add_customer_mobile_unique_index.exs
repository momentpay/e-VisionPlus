defmodule VmuCore.Repo.Migrations.AddCustomerMobileUniqueIndex do
  @moduledoc """
  Cardholder Access (CAM) Phase F1 (2026-08-02) — mobile-number login needs
  `(sys_id, bank_id, mobile_number)` to uniquely identify one customer per
  bank tenant. `cms_customers` had only plain (non-unique) indexes on
  `mobile_number`/`email` before this — matches this codebase's existing
  per-bank-tenant uniqueness convention (see `id_type`/`id_number`
  duplicate-detection in `VmuCore.Shared.Customer.find_duplicates/1`).

  Partial index (`where mobile_number is not null`) since not every
  existing customer row has a mobile number populated.
  """

  use Ecto.Migration

  def change do
    create unique_index(
             :cms_customers,
             [:sys_id, :bank_id, :mobile_number],
             name: :cms_customers_sys_bank_mobile_index,
             where: "mobile_number IS NOT NULL"
           )
  end
end
