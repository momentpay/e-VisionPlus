# KYC-P1..P5 follow-up (2026-07-29) -- real demo data across every product,
# requested by the user after seeing the module live: "seed the data for
# wallet, KYC methods for all product (with conditional field, OCR and
# Validation) and KYC request."
#
# What this seeds:
#   1. Wallet accounts (WalletProduct+WalletAccount) for 3 existing demo
#      customers who don't have one yet -- Wallet had zero seed data before
#      this script, unlike every other product.
#   2. A Fleet vehicle + fleet card for Zaabi Group LLC (Rashid Al Mulla,
#      who already works there per his seeded email domain) -- the one
#      product_type with no real target account to KYC against yet
#      (CORPORATE_FLEET had zero arrangements in the DB before this).
#   3. One KYC Method per product_type (CREDIT gets two, step 1+2, to
#      demonstrate the sequential-gate journey feature) -- every single one
#      carries a self-contained conditional-logic pair (the condition's
#      source field and the field it targets are always on the SAME
#      method/step, since Kyc.ConditionalLogic evaluates against one
#      request's own `data`, not across steps) and at least one `file`-type
#      field (OCR runs automatically on upload, no per-field config needed).
#   4. Real KYC requests against real customers/accounts: some approved
#      (proving Kyc.StatusSync actually flips the real per-product
#      kyc_status flag), some left submitted (populating the Requests
#      queue), one rejected, and for CREDIT specifically one customer with
#      only step 1 approved (showing a real in-progress journey) and
#      another with both steps approved (a completed one).
#
# Deliberately NOT uploading real documents for `file`-type fields -- that's
# a distinct admin action (the Documents panel) in the real flow, not part
# of submitting the form itself, and inventing fake file bytes here wouldn't
# demonstrate anything upload_document/OCR tests don't already cover for
# real. `data` simply omits those keys, same as an admin who filled the form
# and hasn't gotten to the upload step yet.
#
# Idempotent: methods are skipped by name if they already exist; wallets and
# the fleet card are skipped if the customer/company already has one; each
# demo request is looked up by application-number-free product+customer+step
# before creating a duplicate.
#
#   mix run priv/repo/seed_kyc_demo.exs

import Ecto.Query

alias VmuCore.Repo
alias VmuCore.Shared.Customer
alias VmuCore.CMS.{Arrangements, WalletProductOpening}
alias VmuCore.HCS.{Company, Vehicle, FleetCard}
alias VmuCore.Kyc.{Method, Methods, Requests}

find_customer = fn email -> Repo.get_by!(Customer, email: email) end
operator_id = "00000000-0000-0000-0000-000000000001"

# ---------------------------------------------------------------------------
# 1. Wallet accounts (Wallet had zero seed data before this)
# ---------------------------------------------------------------------------

IO.puts("==> Seeding Wallet accounts...")

open_wallet = fn email ->
  customer = find_customer.(email)

  if Repo.exists?(from w in VmuCore.CMS.WalletAccount, where: w.customer_id == ^customer.customer_id) do
    IO.puts("  #{email}: already has a Wallet account, skipped")
  else
    {:ok, %{account: account}} =
      WalletProductOpening.open(%{
        customer_id: customer.customer_id,
        name: "#{customer.first_name} #{customer.last_name}'s Wallet",
        sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", block_id: "MMBC",
        currency: "AED"
      })

    IO.puts("  #{email}: Wallet account opened (#{account.wallet_account_id |> to_string() |> String.slice(0, 8)})")
  end
end

open_wallet.("ahmed.alrashid@email.ae")
open_wallet.("jennifer.wu@globalcorp.com")
open_wallet.("m.alfarsi@alfarsitrading.ae")

# ---------------------------------------------------------------------------
# 2. Fleet vehicle + card for Zaabi Group LLC (the one product with zero
#    real target accounts before this script)
# ---------------------------------------------------------------------------

IO.puts("==> Seeding a Fleet vehicle + card for Zaabi Group LLC...")

zaabi = Repo.get_by!(Company, company_code: "ZAABI")
rashid = find_customer.("rashid.almulla@zaabi-group.ae")

_fleet_card =
  case Repo.one(from f in FleetCard, where: f.company_id == ^zaabi.id, limit: 1) do
    nil ->
      vehicle =
        case Repo.get_by(Vehicle, plate_number: "DXB-A-77234") do
          nil ->
            {:ok, vehicle} =
              %Vehicle{}
              |> Vehicle.changeset(%{company_id: zaabi.id, plate_number: "DXB-A-77234", make: "Toyota", model: "Hiace", year: 2024})
              |> Repo.insert()

            vehicle

          existing_vehicle ->
            existing_vehicle
        end

      # account_id references cms_accounts (real FK) -- fleet cards draw
      # from the company's own central facility (liability_model:
      # "CENTRAL"), same account already linked as parent_account_id.
      {:ok, card} =
        %FleetCard{}
        |> FleetCard.changeset(%{
          company_id: zaabi.id, vehicle_id: vehicle.id, account_id: zaabi.parent_account_id,
          card_type: "FUEL", individual_limit: Decimal.new(3000), available_individual: Decimal.new(3000)
        })
        |> Repo.insert()

      case Arrangements.record(%{customer_id: rashid.customer_id, product_type: "CORPORATE_FLEET", account_ref: to_string(card.id)}) do
        {:ok, _} -> IO.puts("  Zaabi Group LLC: vehicle #{vehicle.plate_number} + fleet card + arrangement created")
        {:error, _} -> IO.puts("  Zaabi Group LLC: fleet card created, arrangement already present")
      end

      card

    existing ->
      IO.puts("  Zaabi Group LLC: already has a fleet card, skipped")
      existing
  end

# ---------------------------------------------------------------------------
# 3. KYC Methods -- one per product, every one with a self-contained
#    conditional-logic pair and at least one file (OCR-eligible) field.
# ---------------------------------------------------------------------------

IO.puts("==> Seeding KYC methods for all products...")

create_method = fn attrs ->
  case Repo.get_by(Method, name: attrs["name"]) do
    nil ->
      {:ok, method} = Methods.create(attrs)
      IO.puts("  created: #{attrs["name"]} (#{attrs["product_type"]}, step #{attrs["step"] || 1})")
      method

    existing ->
      IO.puts("  already exists: #{attrs["name"]}, skipped")
      existing
  end
end

credit_step1 =
  create_method.(%{
    "name" => "Credit - Personal & Contact Details",
    "title" => "Personal & Contact Details",
    "product_type" => "CREDIT",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "email", "label" => "Email Address", "type" => "email", "required" => true, "options" => []},
      %{"key" => "date_of_birth", "label" => "Date of Birth", "type" => "date", "required" => true, "options" => []},
      %{"key" => "nationality", "label" => "Nationality", "type" => "select", "required" => true,
        "options" => ["UAE", "India", "Pakistan", "Philippines", "UK", "USA", "Other"]},
      %{"key" => "passport_number", "label" => "Passport Number", "type" => "text", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "passport_number", "condition" => %{"field" => "nationality", "operator" => "not_equals", "value" => "UAE"}}
    ]
  })

credit_step2 =
  create_method.(%{
    "name" => "Credit - Identity & Address Verification",
    "title" => "Identity & Address Verification",
    "product_type" => "CREDIT",
    "status" => "active",
    "step" => 2,
    "fields" => [
      %{"key" => "emirates_id_number", "label" => "Emirates ID Number", "type" => "text", "required" => true, "options" => []},
      %{"key" => "emirates_id_front", "label" => "Emirates ID (Front)", "type" => "file", "required" => true, "options" => []},
      %{"key" => "emirates_id_back", "label" => "Emirates ID (Back)", "type" => "file", "required" => true, "options" => []},
      %{"key" => "residence_type", "label" => "Residence Type", "type" => "select", "required" => true, "options" => ["Owned", "Rented"]},
      %{"key" => "tenancy_contract_doc", "label" => "Tenancy Contract (Ejari)", "type" => "file", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "tenancy_contract_doc", "condition" => %{"field" => "residence_type", "operator" => "equals", "value" => "Rented"}}
    ]
  })

debit_method =
  create_method.(%{
    "name" => "Debit - Account Holder Verification",
    "title" => "Account Holder Verification",
    "product_type" => "DEBIT",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "mobile_number", "label" => "Mobile Number", "type" => "tel", "required" => true, "options" => []},
      %{"key" => "emirates_id_front", "label" => "Emirates ID (Front)", "type" => "file", "required" => true, "options" => []},
      %{"key" => "employment_status", "label" => "Employment Status", "type" => "select", "required" => true,
        "options" => ["Employed", "Self-Employed", "Unemployed", "Student"]},
      %{"key" => "employer_name", "label" => "Employer Name", "type" => "text", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "employer_name", "condition" => %{"field" => "employment_status", "operator" => "equals", "value" => "Employed"}}
    ]
  })

prepaid_method =
  create_method.(%{
    "name" => "Prepaid - Cardholder Details",
    "title" => "Cardholder Details",
    "product_type" => "PREPAID",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "email", "label" => "Email Address", "type" => "email", "required" => true, "options" => []},
      %{"key" => "id_document", "label" => "ID Document", "type" => "file", "required" => true, "options" => []},
      %{"key" => "purpose", "label" => "Purpose", "type" => "select", "required" => true,
        "options" => ["Personal", "Gift", "Travel", "Business"]},
      %{"key" => "company_name", "label" => "Company Name", "type" => "text", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "company_name", "condition" => %{"field" => "purpose", "operator" => "equals", "value" => "Business"}}
    ]
  })

wallet_method =
  create_method.(%{
    "name" => "Wallet - Digital Wallet KYC",
    "title" => "Digital Wallet KYC",
    "product_type" => "WALLET",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "email", "label" => "Email Address", "type" => "email", "required" => true, "options" => []},
      %{"key" => "phone", "label" => "Phone Number", "type" => "tel", "required" => true, "options" => []},
      %{"key" => "monthly_income_range", "label" => "Monthly Income Range (AED)", "type" => "select", "required" => true,
        "options" => ["Below 5000", "5000-15000", "15000-30000", "Above 30000"]},
      %{"key" => "source_of_funds_doc", "label" => "Source of Funds Document", "type" => "file", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "source_of_funds_doc", "condition" => %{"field" => "monthly_income_range", "operator" => "equals", "value" => "Above 30000"}}
    ]
  })

corporate_facility_method =
  create_method.(%{
    "name" => "Corporate Facility - Business KYB",
    "title" => "Business KYB",
    "product_type" => "CORPORATE_FACILITY",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "company_name", "label" => "Company Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "trade_license_number", "label" => "Trade License Number", "type" => "text", "required" => true, "options" => []},
      %{"key" => "trade_license_doc", "label" => "Trade License Document", "type" => "file", "required" => true, "options" => []},
      %{"key" => "business_type", "label" => "Business Type", "type" => "select", "required" => true,
        "options" => ["LLC", "Sole Establishment", "Free Zone", "Branch"]},
      %{"key" => "vat_registered", "label" => "VAT Registered?", "type" => "select", "required" => true, "options" => ["Yes", "No"]},
      %{"key" => "vat_trn", "label" => "VAT TRN", "type" => "text", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "vat_trn", "condition" => %{"field" => "vat_registered", "operator" => "equals", "value" => "Yes"}}
    ]
  })

corporate_employee_method =
  create_method.(%{
    "name" => "Corporate Employee - Card Verification",
    "title" => "Employee Card Verification",
    "product_type" => "CORPORATE_EMPLOYEE",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "full_name", "label" => "Full Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "emirates_id_number", "label" => "Emirates ID Number", "type" => "text", "required" => true, "options" => []},
      %{"key" => "emirates_id_doc", "label" => "Emirates ID Document", "type" => "file", "required" => true, "options" => []},
      %{"key" => "employee_id", "label" => "Employee ID", "type" => "text", "required" => true, "options" => []},
      %{"key" => "department", "label" => "Department", "type" => "select", "required" => true,
        "options" => ["Finance", "Operations", "Sales", "IT", "HR", "Other"]},
      %{"key" => "other_department", "label" => "Please specify department", "type" => "text", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "other_department", "condition" => %{"field" => "department", "operator" => "equals", "value" => "Other"}}
    ]
  })

corporate_fleet_method =
  create_method.(%{
    "name" => "Corporate Fleet - Driver & Vehicle Verification",
    "title" => "Driver & Vehicle Verification",
    "product_type" => "CORPORATE_FLEET",
    "status" => "active",
    "step" => 1,
    "fields" => [
      %{"key" => "driver_name", "label" => "Driver Name", "type" => "text", "required" => true, "options" => []},
      %{"key" => "driver_license_number", "label" => "Driver License Number", "type" => "text", "required" => true, "options" => []},
      %{"key" => "driver_license_doc", "label" => "Driver License Document", "type" => "file", "required" => true, "options" => []},
      %{"key" => "vehicle_usage", "label" => "Vehicle Usage", "type" => "select", "required" => true,
        "options" => ["Delivery", "Company Car", "Heavy Goods", "Passenger Transport"]},
      %{"key" => "heavy_goods_license_doc", "label" => "Heavy Goods License Document", "type" => "file", "required" => false, "options" => []}
    ],
    "conditional_rules" => [
      %{"target_field" => "heavy_goods_license_doc", "condition" => %{"field" => "vehicle_usage", "operator" => "equals", "value" => "Heavy Goods"}}
    ]
  })

# ---------------------------------------------------------------------------
# 4. KYC Requests -- real customers/accounts, a mix of statuses.
# ---------------------------------------------------------------------------

IO.puts("==> Seeding KYC requests...")

submit_if_new = fn method, customer, data ->
  already =
    Repo.exists?(
      from r in VmuCore.Kyc.Request,
        where: r.kyc_method_id == ^method.method_id and r.customer_id == ^customer.customer_id
    )

  if already do
    IO.puts("  #{customer.first_name} #{customer.last_name} / #{method.name}: request already exists, skipped")
    Repo.one!(
      from r in VmuCore.Kyc.Request,
        where: r.kyc_method_id == ^method.method_id and r.customer_id == ^customer.customer_id,
        limit: 1
    )
  else
    {:ok, request} = Requests.submit(method, %{"customer_id" => customer.customer_id, "data" => data})
    IO.puts("  #{customer.first_name} #{customer.last_name} / #{method.name}: submitted (#{request.application_number})")
    request
  end
end

approve_if_pending = fn request ->
  if request.status == "submitted" do
    case Requests.approve(request, operator_id, "KYC demo data — approved") do
      {:ok, approved} ->
        IO.puts("    -> approved")
        approved

      {:error, reason} ->
        IO.puts("    -> approve failed: #{inspect(reason)}")
        request
    end
  else
    request
  end
end

# CREDIT: Ahmed finishes both steps (a completed journey); Sara only step 1
# (an in-progress journey, step 2 shows "current" in the wizard).
ahmed = find_customer.("ahmed.alrashid@email.ae")
sara = find_customer.("sara.almansouri@email.ae")

submit_if_new.(credit_step1, ahmed, %{
  "full_name" => "Ahmed Al Rashid", "email" => ahmed.email, "date_of_birth" => "1988-04-12", "nationality" => "UAE"
})
|> approve_if_pending.()

submit_if_new.(credit_step2, ahmed, %{
  "emirates_id_number" => "784-1988-1234567-1", "residence_type" => "Owned"
})
|> approve_if_pending.()

submit_if_new.(credit_step1, sara, %{
  "full_name" => "Sara Al Mansouri", "email" => sara.email, "date_of_birth" => "1991-09-03", "nationality" => "UAE"
})
|> approve_if_pending.()

# Left as "submitted" on purpose -- Sara's step 2 is now the visible
# "current" step in her journey, not started yet.

# DEBIT: Abdullah approved, Ahmed rejected (variety in the queue).
abdullah = find_customer.("cfo@zaabi-group.ae")

submit_if_new.(debit_method, abdullah, %{
  "full_name" => "Abdullah Al Zaabi", "mobile_number" => "+971501234006", "employment_status" => "Self-Employed"
})
|> approve_if_pending.()

ahmed_debit_request =
  submit_if_new.(debit_method, ahmed, %{
    "full_name" => "Ahmed Al Rashid", "mobile_number" => "+971501234001", "employment_status" => "Employed", "employer_name" => "Emirates Group"
  })

if ahmed_debit_request.status == "submitted" do
  {:ok, _} = Requests.reject(ahmed_debit_request, operator_id, "Employer letter didn't match employer_name on file — demo rejection")
  IO.puts("    -> rejected (demo)")
end

# PREPAID: Priya approved (Personal), Khalid submitted (Business, exercises
# the conditional company_name field).
priya = find_customer.("priya.sharma@email.com")
khalid = find_customer.("khalid.alshamsi@shamsi.ae")

submit_if_new.(prepaid_method, priya, %{"full_name" => "Priya Sharma", "email" => priya.email, "purpose" => "Gift"})
|> approve_if_pending.()

submit_if_new.(prepaid_method, khalid, %{
  "full_name" => "Khalid Al Shamsi", "email" => khalid.email, "purpose" => "Business", "company_name" => "Al Shamsi Trading"
})

# WALLET: Ahmed approved, Jennifer submitted (Above 30000, exercises the
# conditional source-of-funds field).
jennifer = find_customer.("jennifer.wu@globalcorp.com")

submit_if_new.(wallet_method, ahmed, %{
  "full_name" => "Ahmed Al Rashid", "email" => ahmed.email, "phone" => "+971501234001", "monthly_income_range" => "5000-15000"
})
|> approve_if_pending.()

submit_if_new.(wallet_method, jennifer, %{
  "full_name" => "Jennifer Wu", "email" => jennifer.email, "phone" => "+971501234005", "monthly_income_range" => "Above 30000"
})

# CORPORATE_FACILITY: both existing companies get a fresh KYB request,
# approved (StatusSync re-verifies Company.kyc_status via the real module
# this time, not the old ad-hoc button).
mohammad = find_customer.("m.alfarsi@alfarsitrading.ae")

submit_if_new.(corporate_facility_method, abdullah, %{
  "company_name" => "Zaabi Group LLC", "trade_license_number" => "CN-1122334", "business_type" => "LLC", "vat_registered" => "Yes", "vat_trn" => "100223344500003"
})
|> approve_if_pending.()

submit_if_new.(corporate_facility_method, mohammad, %{
  "company_name" => "Al Farsi Trading Co", "trade_license_number" => "CN-5566778", "business_type" => "Sole Establishment", "vat_registered" => "No"
})
|> approve_if_pending.()

# CORPORATE_EMPLOYEE: Fatima (works at Zaabi per her seeded email) approved.
fatima = find_customer.("fatima.alkhoori@zaabi-group.ae")

submit_if_new.(corporate_employee_method, fatima, %{
  "full_name" => "Fatima Al Khoori", "emirates_id_number" => "784-1993-7654321-2", "employee_id" => "ZG-0042", "department" => "Finance"
})
|> approve_if_pending.()

# CORPORATE_FLEET: Rashid (the fleet card's linked customer) submitted,
# left pending -- shows a real request against the fleet card seeded above.
submit_if_new.(corporate_fleet_method, rashid, %{
  "driver_name" => "Rashid Al Mulla", "driver_license_number" => "DXB-DL-889231", "vehicle_usage" => "Delivery"
})

IO.puts("==> Done.")
