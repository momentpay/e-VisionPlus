alias VmuCore.Repo

now_naive = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
now_utc   = DateTime.utc_now() |> DateTime.truncate(:second)
today     = Date.utc_today()

# Repo.insert_all with raw table names has no schema context, so Postgrex
# expects 16-byte binaries for UUID columns rather than 36-char strings.
uid = fn -> Ecto.UUID.dump!(Ecto.UUID.generate()) end

IO.puts("==> Seeding vMu VisionPlus (all phases)...")

# ============================================================
# PHASE 1 — Foundation: Parameters, STIP, CTA Card Stock
# ============================================================
IO.puts("--> Phase 1: Parameters + Card Stock")

Repo.insert_all("sys_parameters", [
  %{sys_id: "MMPD", description: "MomentPay Card Division", base_currency: "AED",
    inserted_at: now_naive, updated_at: now_naive},
  %{sys_id: "MMRW", description: "MomentPay Rewards Division", base_currency: "AED",
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("bank_parameters", [
  %{bank_id: "MMBD", sys_id: "MMPD", description: "MomentPay Bank Dubai",
    country_code: "ARE", inserted_at: now_naive, updated_at: now_naive},
  %{bank_id: "MMBA", sys_id: "MMPD", description: "MomentPay Bank Abu Dhabi",
    country_code: "ARE", inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("logo_parameters", [
  %{logo_id: "MMST", sys_id: "MMPD", bank_id: "MMBD", bin_prefix: "407200",
    description: "MomentPay Standard Visa", inserted_at: now_naive, updated_at: now_naive},
  %{logo_id: "MMPF", sys_id: "MMPD", bank_id: "MMBD", bin_prefix: "524032",
    description: "MomentPay Platinum Mastercard", inserted_at: now_naive, updated_at: now_naive},
  %{logo_id: "MMCR", sys_id: "MMPD", bank_id: "MMBD", bin_prefix: "407210",
    description: "MomentPay Corporate Visa", inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("block_parameters", [
  %{block_id: "MMBC", sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST",
    apr_percentage: Decimal.new("20.00"), cash_advance_fee_percent: Decimal.new("3.00"),
    credit_limit_default: Decimal.new("5000.00"), inserted_at: now_naive, updated_at: now_naive},
  %{block_id: "MMGD", sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST",
    apr_percentage: Decimal.new("18.50"), cash_advance_fee_percent: Decimal.new("2.50"),
    credit_limit_default: Decimal.new("15000.00"), inserted_at: now_naive, updated_at: now_naive},
  %{block_id: "MMPT", sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMPF",
    apr_percentage: Decimal.new("15.00"), cash_advance_fee_percent: Decimal.new("2.00"),
    credit_limit_default: Decimal.new("30000.00"), inserted_at: now_naive, updated_at: now_naive},
  %{block_id: "MMCP", sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMCR",
    apr_percentage: Decimal.new("14.00"), cash_advance_fee_percent: Decimal.new("1.50"),
    credit_limit_default: Decimal.new("100000.00"), inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("stip_thresholds", [
  %{sys_id: "MMPD", logo_id: "MMST", max_amount: Decimal.new("500.00"),
    max_cumulative: Decimal.new("1000.00"), inserted_at: now_naive},
  %{sys_id: "MMPD", logo_id: "MMPF", max_amount: Decimal.new("1000.00"),
    max_cumulative: Decimal.new("2000.00"), inserted_at: now_naive},
  %{sys_id: "MMPD", logo_id: "MMCR", max_amount: Decimal.new("2000.00"),
    max_cumulative: Decimal.new("5000.00"), inserted_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("cta_card_stock", [
  %{sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", bin_prefix: "407200",
    batch_number: "VISA-STD-2026-001", quantity_ordered: 5000,
    quantity_on_hand: 4850, quantity_issued: 150, quantity_damaged: 0,
    bureau_name: "Cards Bureau UAE",
    order_date: ~D[2026-01-15], delivery_date: ~D[2026-02-01],
    expiry_year_month: "2901", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive},
  %{sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMPF", bin_prefix: "524032",
    batch_number: "MC-PLAT-2026-001", quantity_ordered: 2000,
    quantity_on_hand: 1960, quantity_issued: 40, quantity_damaged: 0,
    bureau_name: "Cards Bureau UAE",
    order_date: ~D[2026-01-15], delivery_date: ~D[2026-02-01],
    expiry_year_month: "2901", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive},
  %{sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMCR", bin_prefix: "407210",
    batch_number: "VISA-CORP-2026-001", quantity_ordered: 500,
    quantity_on_hand: 490, quantity_issued: 10, quantity_damaged: 0,
    bureau_name: "Cards Bureau UAE",
    order_date: ~D[2026-01-20], delivery_date: ~D[2026-02-05],
    expiry_year_month: "2901", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

IO.puts("    ✓ Parameters, STIP, card stock")

# ============================================================
# Customers (10 — all tiers including HCS employees)
# ============================================================
[cust_ahmed, cust_sara, cust_priya, cust_mohammad, cust_jennifer,
 cust_abdullah, cust_fiona, cust_khalid, cust_rashid, cust_fatima] =
  Enum.map(1..10, fn _ -> uid.() end)

Repo.insert_all("cms_customers", [
  %{customer_id: cust_ahmed, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Ahmed", last_name: "Al Rashid",
    date_of_birth: ~D[1985-04-12], nationality: "ARE",
    email: "ahmed.alrashid@email.ae", mobile_country: "+971", mobile_number: "501234001",
    address_line1: "Villa 12, Al Barsha", city: "Dubai", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784198504120001", id_expiry: ~D[2030-03-01],
    kyc_status: "VERIFIED", customer_tier: "RETAIL",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_sara, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Sara", last_name: "Al Mansouri",
    date_of_birth: ~D[1992-07-20], nationality: "ARE",
    email: "sara.almansouri@email.ae", mobile_country: "+971", mobile_number: "501234002",
    address_line1: "Apt 305, Jumeirah Beach Rd", city: "Dubai", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784199207200002", id_expiry: ~D[2028-09-15],
    kyc_status: "VERIFIED", customer_tier: "RETAIL",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_priya, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Priya", last_name: "Sharma",
    date_of_birth: ~D[1990-11-05], nationality: "IND",
    email: "priya.sharma@email.com", mobile_country: "+971", mobile_number: "501234003",
    address_line1: "Flat 12B, International City", city: "Dubai", country: "ARE",
    id_type: "PASSPORT", id_number: "P5671234", id_expiry: ~D[2029-06-30],
    kyc_status: "VERIFIED", customer_tier: "RETAIL",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_mohammad, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Mohammad", last_name: "Al Farsi",
    date_of_birth: ~D[1978-03-15], nationality: "ARE",
    email: "m.alfarsi@alfarsitrading.ae", mobile_country: "+971", mobile_number: "501234004",
    address_line1: "Office 1204, DIFC", city: "Dubai", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784197803150004", id_expiry: ~D[2031-02-01],
    kyc_status: "VERIFIED", customer_tier: "BUSINESS",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_jennifer, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Jennifer", last_name: "Wu",
    date_of_birth: ~D[1988-09-28], nationality: "USA",
    email: "jennifer.wu@globalcorp.com", mobile_country: "+971", mobile_number: "501234005",
    address_line1: "Suite 500, Emaar Square", city: "Dubai", country: "ARE",
    id_type: "PASSPORT", id_number: "US123456789", id_expiry: ~D[2027-12-31],
    kyc_status: "VERIFIED", customer_tier: "BUSINESS",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_abdullah, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Abdullah", last_name: "Al Zaabi",
    date_of_birth: ~D[1970-06-10], nationality: "ARE",
    email: "cfo@zaabi-group.ae", mobile_country: "+971", mobile_number: "501234006",
    address_line1: "Floor 22, World Trade Center", city: "Abu Dhabi", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784197006100006", id_expiry: ~D[2032-05-01],
    kyc_status: "VERIFIED", customer_tier: "CORPORATE",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_fiona, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Fiona", last_name: "MacDonald",
    date_of_birth: ~D[1975-01-22], nationality: "GBR",
    email: "fiona.macdonald@fintech.io", mobile_country: "+971", mobile_number: "501234007",
    address_line1: "Penthouse 1, Palm Jumeirah", city: "Dubai", country: "ARE",
    id_type: "PASSPORT", id_number: "GB789012345", id_expiry: ~D[2033-08-20],
    kyc_status: "VERIFIED", customer_tier: "PREMIUM",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_khalid, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Khalid", last_name: "Al Shamsi",
    date_of_birth: ~D[1980-12-03], nationality: "ARE",
    email: "khalid.alshamsi@shamsi.ae", mobile_country: "+971", mobile_number: "501234008",
    address_line1: "Villa 3, Emirates Hills", city: "Dubai", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784198012030008", id_expiry: ~D[2031-11-15],
    kyc_status: "VERIFIED", customer_tier: "PREMIUM",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_rashid, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Rashid", last_name: "Al Mulla",
    date_of_birth: ~D[1990-05-18], nationality: "ARE",
    email: "rashid.almulla@zaabi-group.ae", mobile_country: "+971", mobile_number: "501234009",
    address_line1: "Apt 601, Downtown Dubai", city: "Dubai", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784199005180009", id_expiry: ~D[2030-07-01],
    kyc_status: "VERIFIED", customer_tier: "CORPORATE",
    inserted_at: now_naive, updated_at: now_naive},
  %{customer_id: cust_fatima, sys_id: "MMPD", bank_id: "MMBD",
    first_name: "Fatima", last_name: "Al Khoori",
    date_of_birth: ~D[1993-08-25], nationality: "ARE",
    email: "fatima.alkhoori@zaabi-group.ae", mobile_country: "+971", mobile_number: "501234010",
    address_line1: "Villa 7, Mirdif", city: "Dubai", country: "ARE",
    id_type: "NATIONAL_ID", id_number: "784199308250010", id_expiry: ~D[2029-04-15],
    kyc_status: "VERIFIED", customer_tier: "CORPORATE",
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

IO.puts("    ✓ 10 customers (RETAIL/BUSINESS/CORPORATE/PREMIUM)")

# ============================================================
# PHASE 2 — CMS Accounts + Balance Buckets + GL Ledger
# ============================================================
IO.puts("--> Phase 2: CMS Accounts + GL")

[acc_ahmed, acc_sara, acc_priya, acc_mohammad, acc_jennifer,
 acc_abdullah, acc_fiona, acc_khalid, acc_rashid, acc_fatima] =
  Enum.map(1..10, fn _ -> uid.() end)

pan = fn s -> :crypto.hash(:sha256, s) |> Base.encode16(case: :lower) end

[pan_ahmed, pan_sara, pan_priya, pan_mohammad, pan_jennifer,
 pan_abdullah, pan_fiona, pan_khalid, pan_rashid, pan_fatima] = [
  pan.("4072001234560001"), pan.("4072001234560002"), pan.("4072001234560003"),
  pan.("4072001234560004"), pan.("4072001234560005"), pan.("4072101234560006"),
  pan.("5240321234560007"), pan.("5240321234560008"),
  pan.("4072101234560009"), pan.("4072101234560010")
]

Repo.insert_all("cms_accounts", [
  %{account_id: acc_ahmed, customer_id: cust_ahmed,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", block_id: "MMBC",
    pan_token: pan_ahmed, last_four: "0001", expiry_date: "0129",
    credit_limit: Decimal.new("8000.00"), open_to_buy: Decimal.new("6200.00"),
    cycle_code: 15, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{"POS" => %{"daily_count" => 10, "daily_amount" => 2000}},
    open_date: ~D[2024-03-01], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_sara, customer_id: cust_sara,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", block_id: "MMBC",
    pan_token: pan_sara, last_four: "0002", expiry_date: "0129",
    credit_limit: Decimal.new("5000.00"), open_to_buy: Decimal.new("4750.00"),
    cycle_code: 20, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2024-06-15], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_priya, customer_id: cust_priya,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", block_id: "MMGD",
    pan_token: pan_priya, last_four: "0003", expiry_date: "0129",
    credit_limit: Decimal.new("12000.00"), open_to_buy: Decimal.new("9800.00"),
    cycle_code: 25, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{"ECOM" => %{"daily_amount" => 3000}},
    open_date: ~D[2023-11-01], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_mohammad, customer_id: cust_mohammad,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", block_id: "MMGD",
    pan_token: pan_mohammad, last_four: "0004", expiry_date: "0129",
    credit_limit: Decimal.new("25000.00"), open_to_buy: Decimal.new("22000.00"),
    cycle_code: 10, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2024-01-10], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_jennifer, customer_id: cust_jennifer,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST", block_id: "MMBC",
    pan_token: pan_jennifer, last_four: "0005", expiry_date: "0128",
    credit_limit: Decimal.new("10000.00"), open_to_buy: Decimal.new("0.00"),
    cycle_code: 5, account_status: "DELINQUENT", delinquency_bucket: 60,
    velocity_limits: %{},
    open_date: ~D[2023-05-20], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_abdullah, customer_id: cust_abdullah,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMCR", block_id: "MMCP",
    pan_token: pan_abdullah, last_four: "0006", expiry_date: "0129",
    credit_limit: Decimal.new("500000.00"), open_to_buy: Decimal.new("350000.00"),
    cycle_code: 25, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2023-08-01], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_fiona, customer_id: cust_fiona,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMPF", block_id: "MMPT",
    pan_token: pan_fiona, last_four: "0007", expiry_date: "0129",
    credit_limit: Decimal.new("50000.00"), open_to_buy: Decimal.new("47000.00"),
    cycle_code: 1, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2024-02-14], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_khalid, customer_id: cust_khalid,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMPF", block_id: "MMPT",
    pan_token: pan_khalid, last_four: "0008", expiry_date: "0129",
    credit_limit: Decimal.new("75000.00"), open_to_buy: Decimal.new("68000.00"),
    cycle_code: 15, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2023-06-01], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_rashid, customer_id: cust_rashid,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMCR", block_id: "MMCP",
    pan_token: pan_rashid, last_four: "0009", expiry_date: "0129",
    credit_limit: Decimal.new("15000.00"), open_to_buy: Decimal.new("12500.00"),
    cycle_code: 25, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2024-01-15], inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_fatima, customer_id: cust_fatima,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMCR", block_id: "MMCP",
    pan_token: pan_fatima, last_four: "0010", expiry_date: "0129",
    credit_limit: Decimal.new("10000.00"), open_to_buy: Decimal.new("9000.00"),
    cycle_code: 25, account_status: "ACTIVE", delinquency_bucket: 0,
    velocity_limits: %{},
    open_date: ~D[2024-01-15], inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

# Balance Buckets
Repo.insert_all("cms_balance_buckets", [
  %{account_id: acc_ahmed, retail_balance: Decimal.new("1800.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("1800.00"), minimum_payment: Decimal.new("90.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_sara, retail_balance: Decimal.new("250.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("250.00"), minimum_payment: Decimal.new("25.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_priya, retail_balance: Decimal.new("2200.00"),
    cash_balance: Decimal.new("500.00"), accrued_interest: Decimal.new("12.50"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("349.00"),
    statement_balance: Decimal.new("2700.00"), minimum_payment: Decimal.new("135.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_mohammad, retail_balance: Decimal.new("3000.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("3000.00"), minimum_payment: Decimal.new("150.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_jennifer, retail_balance: Decimal.new("9800.00"),
    cash_balance: Decimal.new("200.00"), accrued_interest: Decimal.new("285.60"),
    unpaid_fees: Decimal.new("150.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("10235.60"), minimum_payment: Decimal.new("511.78"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_abdullah, retail_balance: Decimal.new("150000.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("150000.00"), minimum_payment: Decimal.new("7500.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_fiona, retail_balance: Decimal.new("3000.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("3000.00"), minimum_payment: Decimal.new("150.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_khalid, retail_balance: Decimal.new("7000.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("7000.00"), minimum_payment: Decimal.new("350.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_rashid, retail_balance: Decimal.new("2500.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("2500.00"), minimum_payment: Decimal.new("125.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive},
  %{account_id: acc_fatima, retail_balance: Decimal.new("1000.00"),
    cash_balance: Decimal.new("0.00"), accrued_interest: Decimal.new("0.00"),
    unpaid_fees: Decimal.new("0.00"), disputed_amount: Decimal.new("0.00"),
    statement_balance: Decimal.new("1000.00"), minimum_payment: Decimal.new("50.00"),
    balance_date: today, inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

# GL Ledger entries — representative transactions per account
Repo.insert_all("cms_ledger_entries", [
  %{entry_id: uid.(), account_id: acc_ahmed,
    idempotency_key: "SEED-GL-AHMED-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("450.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -15), value_date: Date.add(today, -15),
    narrative: "Carrefour Dubai - Groceries",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_ahmed,
    idempotency_key: "SEED-GL-AHMED-PAY-001", transaction_code: "PAYMENT",
    dr_amount: Decimal.new("0.00"), cr_amount: Decimal.new("500.00"),
    gl_account_dr: "2001", gl_account_cr: "1001", currency: "AED",
    posting_date: Date.add(today, -10), value_date: Date.add(today, -10),
    narrative: "Bank transfer payment",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_priya,
    idempotency_key: "SEED-GL-PRIYA-CASH-001", transaction_code: "CASH_ADV",
    dr_amount: Decimal.new("500.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1002", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -20), value_date: Date.add(today, -20),
    narrative: "ATM Withdrawal - Al Barsha",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_priya,
    idempotency_key: "SEED-GL-PRIYA-INT-001", transaction_code: "INTEREST",
    dr_amount: Decimal.new("12.50"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1003", gl_account_cr: "4002", currency: "AED",
    posting_date: Date.add(today, -1), value_date: Date.add(today, -1),
    narrative: "Monthly interest accrual",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_jennifer,
    idempotency_key: "SEED-GL-JENNIFER-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("9800.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -90), value_date: Date.add(today, -90),
    narrative: "Emirates Electronics - Laptop",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_jennifer,
    idempotency_key: "SEED-GL-JENNIFER-FEE-001", transaction_code: "FEE",
    dr_amount: Decimal.new("150.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1004", gl_account_cr: "4001", currency: "AED",
    posting_date: Date.add(today, -60), value_date: Date.add(today, -60),
    narrative: "Late payment fee",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_mohammad,
    idempotency_key: "SEED-GL-MOHAMMAD-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("3000.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -5), value_date: Date.add(today, -5),
    narrative: "Office Supplies - IKEA", inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_abdullah,
    idempotency_key: "SEED-GL-ABDULLAH-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("75000.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -8), value_date: Date.add(today, -8),
    narrative: "Emirates Airlines - Business Travel",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_khalid,
    idempotency_key: "SEED-GL-KHALID-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("7000.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -12), value_date: Date.add(today, -12),
    narrative: "Rolex Boutique - Dubai Mall",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_rashid,
    idempotency_key: "SEED-GL-RASHID-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("2500.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -7), value_date: Date.add(today, -7),
    narrative: "Business Dinner - Four Seasons",
    inserted_at: now_naive, updated_at: now_naive},
  %{entry_id: uid.(), account_id: acc_fatima,
    idempotency_key: "SEED-GL-FATIMA-PUR-001", transaction_code: "PURCHASE",
    dr_amount: Decimal.new("1000.00"), cr_amount: Decimal.new("0.00"),
    gl_account_dr: "1001", gl_account_cr: "2001", currency: "AED",
    posting_date: Date.add(today, -4), value_date: Date.add(today, -4),
    narrative: "Office Stationery - Viking Direct",
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

IO.puts("    ✓ 10 accounts, balance buckets, 11 GL entries")

# ============================================================
# PHASE 3 — DPS Disputes
# ============================================================
IO.puts("--> Phase 3: DPS Disputes")

[disp1, disp2, disp3, disp4] = Enum.map(1..4, fn _ -> uid.() end)

Repo.insert_all("dps_disputes", [
  %{dispute_id: disp1, account_id: acc_priya,
    transaction_date: Date.add(today, -45), dispute_amount: Decimal.new("349.00"),
    currency: "AED", reason_code: "4853", network: "MC",
    status: "RETRIEVAL_REQUESTED", network_ref: "MC-2026-RET-00123",
    provisional_credit_posted: true,
    chargeback_deadline: Date.add(today, 75),
    representment_deadline: Date.add(today, 105),
    pre_arb_deadline: Date.add(today, 135),
    filed_at: NaiveDateTime.add(now_naive, -45 * 86400),
    inserted_at: now_naive, updated_at: now_naive},
  %{dispute_id: disp2, account_id: acc_ahmed,
    transaction_date: Date.add(today, -30), dispute_amount: Decimal.new("210.00"),
    currency: "AED", reason_code: "30", network: "VI",
    status: "FILED",
    provisional_credit_posted: true,
    chargeback_deadline: Date.add(today, 90),
    representment_deadline: Date.add(today, 120),
    pre_arb_deadline: Date.add(today, 150),
    filed_at: NaiveDateTime.add(now_naive, -2 * 86400),
    inserted_at: now_naive, updated_at: now_naive},
  %{dispute_id: disp3, account_id: acc_mohammad,
    transaction_date: Date.add(today, -80), dispute_amount: Decimal.new("1500.00"),
    currency: "AED", reason_code: "4837", network: "MC",
    status: "CHARGEBACK_FILED", network_ref: "MC-2026-CB-00456",
    provisional_credit_posted: true,
    chargeback_deadline: Date.add(today, 40),
    representment_deadline: Date.add(today, 70),
    pre_arb_deadline: Date.add(today, 100),
    filed_at: NaiveDateTime.add(now_naive, -60 * 86400),
    inserted_at: now_naive, updated_at: now_naive},
  %{dispute_id: disp4, account_id: acc_khalid,
    transaction_date: Date.add(today, -120), dispute_amount: Decimal.new("5000.00"),
    currency: "AED", reason_code: "4834", network: "MC",
    status: "CLOSED_WIN", network_ref: "MC-2026-WIN-00789",
    provisional_credit_posted: true,
    chargeback_deadline: Date.add(today, -30),
    representment_deadline: Date.add(today, 0),
    pre_arb_deadline: Date.add(today, 30),
    filed_at: NaiveDateTime.add(now_naive, -100 * 86400),
    closed_at: NaiveDateTime.add(now_naive, -5 * 86400),
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

IO.puts("    ✓ 4 disputes (FILED / RETRIEVAL_REQUESTED / CHARGEBACK_FILED / CLOSED_WIN)")

# ============================================================
# PHASE 4 — TRAMS Clearing Records + COL Collection Cases
# ============================================================
IO.puts("--> Phase 4: TRAMS + COL")

[cr1, cr2, cr3, cr4, cr5, cr6] = Enum.map(1..6, fn _ -> uid.() end)

Repo.insert_all("trams_clearing_records", [
  %{clearing_id: cr1, account_id: acc_ahmed, network: "MC",
    file_name: "IPM_20260610_001.dat", record_type: "1240", pan_token: pan_ahmed,
    transaction_date: Date.add(today, -15), settlement_date: Date.add(today, -13),
    amount: Decimal.new("450.00"), currency: "AED",
    interchange_fee: Decimal.new("7.43"), mcc: "5411",
    acquirer_id: "40000001234", rrn: "265001234567", auth_code: "123456",
    match_status: "MATCHED", inserted_at: now_naive, updated_at: now_naive},
  %{clearing_id: cr2, account_id: acc_priya, network: "MC",
    file_name: "IPM_20260610_001.dat", record_type: "1240", pan_token: pan_priya,
    transaction_date: Date.add(today, -20), settlement_date: Date.add(today, -18),
    amount: Decimal.new("500.00"), currency: "AED",
    interchange_fee: Decimal.new("8.25"), mcc: "6010",
    acquirer_id: "40000001235", rrn: "265001234568", auth_code: "234567",
    match_status: "MATCHED", inserted_at: now_naive, updated_at: now_naive},
  %{clearing_id: cr3, account_id: acc_mohammad, network: "VI",
    file_name: "BASEII_20260605_001.dat", record_type: "TC05", pan_token: pan_mohammad,
    transaction_date: Date.add(today, -5), settlement_date: Date.add(today, -3),
    amount: Decimal.new("3000.00"), currency: "AED",
    interchange_fee: Decimal.new("52.50"), mcc: "5943",
    acquirer_id: "40000002001", rrn: "157001234569", auth_code: "345678",
    match_status: "MATCHED", inserted_at: now_naive, updated_at: now_naive},
  %{clearing_id: cr4, account_id: acc_abdullah, network: "MC",
    file_name: "IPM_20260608_001.dat", record_type: "1240", pan_token: pan_abdullah,
    transaction_date: Date.add(today, -8), settlement_date: Date.add(today, -6),
    amount: Decimal.new("75000.00"), currency: "AED",
    interchange_fee: Decimal.new("1237.50"), mcc: "4511",
    acquirer_id: "40000001500", rrn: "265001234570", auth_code: "456789",
    match_status: "MATCHED", inserted_at: now_naive, updated_at: now_naive},
  %{clearing_id: cr5, network: "VI",
    file_name: "BASEII_20260601_002.dat", record_type: "TC05",
    pan_token: pan.("4072001111111999"),
    transaction_date: Date.add(today, -12), settlement_date: Date.add(today, -10),
    amount: Decimal.new("175.50"), currency: "AED",
    interchange_fee: Decimal.new("2.89"), mcc: "5812",
    acquirer_id: "40000003001", rrn: "157001234571", auth_code: "567890",
    match_status: "UNMATCHED", inserted_at: now_naive, updated_at: now_naive},
  %{clearing_id: cr6, account_id: acc_khalid, network: "MC",
    file_name: "IPM_20260612_001.dat", record_type: "1240", pan_token: pan_khalid,
    transaction_date: Date.add(today, -12), settlement_date: Date.add(today, -10),
    amount: Decimal.new("7000.00"), currency: "AED",
    interchange_fee: Decimal.new("115.50"), mcc: "5944",
    acquirer_id: "40000001234", rrn: "265001234572", auth_code: "678901",
    match_status: "MATCHED", inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

[col1, col2] = Enum.map(1..2, fn _ -> uid.() end)

Repo.insert_all("col_collection_cases", [
  %{case_id: col1, account_id: acc_jennifer,
    dpd_bucket: 60, outstanding_amount: Decimal.new("10235.60"),
    status: "OPEN", assigned_to: "AGENT-COL-007",
    inserted_at: now_naive, updated_at: now_naive},
  %{case_id: col2, account_id: acc_jennifer,
    dpd_bucket: 60, outstanding_amount: Decimal.new("10235.60"),
    status: "PROMISED", assigned_to: "AGENT-COL-007",
    promise_date: Date.add(today, 7), promise_amount: Decimal.new("2000.00"),
    inserted_at: NaiveDateTime.add(now_naive, -2 * 86400),
    updated_at: NaiveDateTime.add(now_naive, -1 * 86400)}
], on_conflict: :nothing)

IO.puts("    ✓ 6 clearing records (MC + VI), 2 collection cases")

# ============================================================
# PHASE 5 — CDM + MBS Merchants + Terminals + Operator Audit
# ============================================================
IO.puts("--> Phase 5: CDM + MBS + Operators")

[app1, app2, app3, app4] = Enum.map(1..4, fn _ -> uid.() end)

Repo.insert_all("cdm_credit_applications", [
  %{application_id: app1, customer_id: cust_ahmed,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST",
    requested_limit: Decimal.new("10000.00"), approved_limit: Decimal.new("8000.00"),
    monthly_income: Decimal.new("15000.00"), employment_type: "EMPLOYED",
    bureau_score: 720, bureau_ref: "AECB-2024-001234",
    risk_tier: "PRIME", status: "APPROVED",
    submitted_at: NaiveDateTime.add(now_naive, -365 * 86400),
    decided_at: NaiveDateTime.add(now_naive, -364 * 86400),
    inserted_at: now_naive, updated_at: now_naive},
  %{application_id: app2, customer_id: cust_jennifer,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST",
    requested_limit: Decimal.new("10000.00"), approved_limit: Decimal.new("10000.00"),
    monthly_income: Decimal.new("12000.00"), employment_type: "EMPLOYED",
    bureau_score: 680, bureau_ref: "AECB-2023-006789",
    risk_tier: "NEAR_PRIME", status: "APPROVED",
    submitted_at: NaiveDateTime.add(now_naive, -400 * 86400),
    decided_at: NaiveDateTime.add(now_naive, -399 * 86400),
    inserted_at: now_naive, updated_at: now_naive},
  %{application_id: app3, customer_id: cust_sara,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST",
    requested_limit: Decimal.new("20000.00"), approved_limit: nil,
    monthly_income: Decimal.new("8000.00"), employment_type: "EMPLOYED",
    bureau_score: 590, bureau_ref: "AECB-2026-011111",
    risk_tier: "SUBPRIME", status: "DECLINED",
    decline_reason: "DSR_CAP_EXCEEDED",
    submitted_at: NaiveDateTime.add(now_naive, -30 * 86400),
    decided_at: NaiveDateTime.add(now_naive, -29 * 86400),
    inserted_at: now_naive, updated_at: now_naive},
  %{application_id: app4, customer_id: cust_mohammad,
    sys_id: "MMPD", bank_id: "MMBD", logo_id: "MMST",
    requested_limit: Decimal.new("30000.00"), approved_limit: Decimal.new("25000.00"),
    monthly_income: Decimal.new("45000.00"), employment_type: "SELF_EMPLOYED",
    bureau_score: 755, bureau_ref: "AECB-2024-009876",
    risk_tier: "PRIME", status: "APPROVED",
    submitted_at: NaiveDateTime.add(now_naive, -180 * 86400),
    decided_at: NaiveDateTime.add(now_naive, -179 * 86400),
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

[merch_carrefour, merch_emirates, merch_rolex, merch_online] =
  Enum.map(1..4, fn _ -> uid.() end)

Repo.insert_all("mbs_merchants", [
  %{merchant_id: merch_carrefour, sys_id: "MMPD", bank_id: "MMBD",
    merchant_name: "Carrefour UAE", merchant_type: "CHAIN", mcc: "5411",
    registration_no: "REG-DXB-00001", vat_no: "100012345600001",
    settlement_bank: "Emirates NBD",
    settlement_iban: "AE070331234567890123456",
    mdr_template_id: "RETAIL-STD", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive},
  %{merchant_id: merch_emirates, sys_id: "MMPD", bank_id: "MMBD",
    merchant_name: "Emirates Airlines", merchant_type: "STANDALONE", mcc: "4511",
    registration_no: "REG-DXB-00002", vat_no: "100012345600002",
    settlement_bank: "Mashreq Bank",
    settlement_iban: "AE060330098765432198765",
    mdr_template_id: "AIRLINE-STD", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive},
  %{merchant_id: merch_rolex, sys_id: "MMPD", bank_id: "MMBD",
    merchant_name: "Rolex Boutique Dubai Mall", merchant_type: "STANDALONE", mcc: "5944",
    registration_no: "REG-DXB-00003", vat_no: "100012345600003",
    settlement_bank: "ADCB",
    settlement_iban: "AE450030012345678901234",
    mdr_template_id: "LUXURY-STD", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive},
  %{merchant_id: merch_online, sys_id: "MMPD", bank_id: "MMBD",
    merchant_name: "ShopME Online", merchant_type: "VIRTUAL", mcc: "5961",
    registration_no: "REG-DXB-00004", vat_no: "100012345600004",
    mdr_template_id: "ECOM-STD", status: "ACTIVE",
    inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("mbs_terminals", [
  %{terminal_id: uid.(), merchant_id: merch_carrefour,
    terminal_code: "CRFM0001", terminal_type: "POS",
    serial_number: "ING-P400-001234", installed_at: ~D[2024-01-10],
    status: "ACTIVE", inserted_at: now_naive, updated_at: now_naive},
  %{terminal_id: uid.(), merchant_id: merch_carrefour,
    terminal_code: "CRFM0002", terminal_type: "MPOS",
    serial_number: "PAX-A920-005678", installed_at: ~D[2024-03-15],
    status: "ACTIVE", inserted_at: now_naive, updated_at: now_naive},
  %{terminal_id: uid.(), merchant_id: merch_emirates,
    terminal_code: "EMRK0001", terminal_type: "KIOSK",
    serial_number: "KIOSK-EK-001", installed_at: ~D[2023-11-01],
    status: "ACTIVE", inserted_at: now_naive, updated_at: now_naive},
  %{terminal_id: uid.(), merchant_id: merch_rolex,
    terminal_code: "ROLX0001", terminal_type: "POS",
    serial_number: "ING-P400-009876", installed_at: ~D[2024-05-20],
    status: "ACTIVE", inserted_at: now_naive, updated_at: now_naive},
  %{terminal_id: uid.(), merchant_id: merch_online,
    terminal_code: "SHPM0001", terminal_type: "VIRTUAL",
    serial_number: "VIRT-SHP-001", installed_at: ~D[2024-02-01],
    status: "ACTIVE", inserted_at: now_naive, updated_at: now_naive}
], on_conflict: :nothing)

Repo.insert_all("cms_operator_audit", [
  %{operator_id: "OPR-001", operator_role: "agent",
    action: "account_view", subject: Ecto.UUID.load!(acc_ahmed),
    details: Jason.encode!(%{reason: "Customer called about statement"}),
    performed_at: NaiveDateTime.add(now_naive, -7 * 86400),
    inserted_at: NaiveDateTime.add(now_naive, -7 * 86400)},
  %{operator_id: "OPR-002", operator_role: "supervisor",
    action: "fee_waiver", subject: Ecto.UUID.load!(acc_jennifer),
    details: Jason.encode!(%{amount: "150.00", reason: "Customer hardship - first time"}),
    performed_at: NaiveDateTime.add(now_naive, -14 * 86400),
    inserted_at: NaiveDateTime.add(now_naive, -14 * 86400)},
  %{operator_id: "OPR-003", operator_role: "manager",
    action: "limit_change", subject: Ecto.UUID.load!(acc_ahmed),
    details: Jason.encode!(%{old_limit: "5000.00", new_limit: "8000.00", reason: "Income increase"}),
    performed_at: NaiveDateTime.add(now_naive, -30 * 86400),
    inserted_at: NaiveDateTime.add(now_naive, -30 * 86400)},
  %{operator_id: "OPR-004", operator_role: "sysadmin",
    action: "parameter_update", subject: "MMPD/MMBD/MMST/MMGD",
    details: Jason.encode!(%{key: "cash_advance_fee_percent", value: "2.50"}),
    performed_at: NaiveDateTime.add(now_naive, -60 * 86400),
    inserted_at: NaiveDateTime.add(now_naive, -60 * 86400)}
], on_conflict: :nothing)

IO.puts("    ✓ 4 CDM applications, 4 merchants, 5 terminals, 4 operator audit entries")

# ============================================================
# PHASE 6 — LMS Loyalty Management System
# ============================================================
IO.puts("--> Phase 6: LMS")

{1, [%{id: scheme_id}]} = Repo.insert_all("lms_schemes", [
  %{scheme_code: "MMPTS", scheme_name: "MomentPay Rewards Programme",
    org_id: 1, currency: "AED", points_expiry_months: 24,
    warehouse_days: 7, cycle_to_date_include: true, status: "ACTIVE",
    inserted_at: now_utc, updated_at: now_utc}
], returning: [:id], on_conflict: :nothing)

{2, [%{id: grp_default}, %{id: grp_dining}]} = Repo.insert_all("lms_groups", [
  %{scheme_id: scheme_id, group_code: "BASE", group_type: "DEFAULT",
    group_name: "Base Earning Group", settlement_account: "LMS-SETT-001",
    status: "ACTIVE", inserted_at: now_utc},
  %{scheme_id: scheme_id, group_code: "DINING", group_type: "BONUS",
    group_name: "Dining & Luxury Bonus", settlement_account: "LMS-SETT-002",
    status: "ACTIVE", inserted_at: now_utc}
], returning: [:id], on_conflict: :nothing)

{3, [%{id: plan_base}, %{id: plan_supp}, %{id: plan_ovr}]} = Repo.insert_all("lms_plans", [
  %{group_id: grp_default, plan_type: "BASE",
    effective_from: ~D[2024-01-01], status: "ACTIVE", inserted_at: now_utc},
  %{group_id: grp_default, plan_type: "SUPPLEMENTARY",
    effective_from: ~D[2024-01-01], effective_to: ~D[2026-12-31],
    status: "ACTIVE", inserted_at: now_utc},
  %{group_id: grp_dining, plan_type: "OVERRIDE",
    effective_from: ~D[2025-01-01], status: "ACTIVE", inserted_at: now_utc}
], returning: [:id], on_conflict: :nothing)

Repo.insert_all("lms_rate_tiers", [
  %{plan_id: plan_base, tier_order: 1, min_amount: Decimal.new("0.01"),
    points_per_unit: Decimal.new("1.0"), min_qualifying_amount: Decimal.new("0.01"),
    inserted_at: now_utc},
  %{plan_id: plan_supp, tier_order: 1, min_amount: Decimal.new("0.01"),
    points_per_unit: Decimal.new("0.5"), min_qualifying_amount: Decimal.new("1.00"),
    inserted_at: now_utc},
  %{plan_id: plan_ovr, tier_order: 1, min_amount: Decimal.new("0.01"),
    max_amount: Decimal.new("5000.00"), points_per_unit: Decimal.new("5.0"),
    min_qualifying_amount: Decimal.new("10.00"), inserted_at: now_utc},
  %{plan_id: plan_ovr, tier_order: 2, min_amount: Decimal.new("5000.01"),
    points_per_unit: Decimal.new("3.0"), min_qualifying_amount: Decimal.new("10.00"),
    inserted_at: now_utc}
], on_conflict: :nothing)

Repo.insert_all("lms_group_merchants", [
  %{group_id: grp_dining, merchant_id: merch_rolex, inserted_at: now_utc},
  %{group_id: grp_dining, merchant_id: merch_emirates, inserted_at: now_utc}
], on_conflict: :nothing)

{2, [%{id: lms_priya}, %{id: lms_khalid}]} = Repo.insert_all("lms_accounts", [
  %{lms_account_no: "MMPTS-00000003", ar_account_id: acc_priya,
    scheme_id: scheme_id, enrollment_date: ~D[2023-11-01],
    enrollment_method: "AUTO", points_balance: Decimal.new("2750.00"),
    open_to_redeem: Decimal.new("2750.00"), lifetime_earned: Decimal.new("3200.00"),
    lifetime_redeemed: Decimal.new("450.00"), status: "ACTIVE",
    inserted_at: now_utc, updated_at: now_utc},
  %{lms_account_no: "MMPTS-00000008", ar_account_id: acc_khalid,
    scheme_id: scheme_id, enrollment_date: ~D[2023-06-01],
    enrollment_method: "AUTO", points_balance: Decimal.new("12500.00"),
    open_to_redeem: Decimal.new("12500.00"), lifetime_earned: Decimal.new("15000.00"),
    lifetime_redeemed: Decimal.new("2500.00"), status: "ACTIVE",
    inserted_at: now_utc, updated_at: now_utc}
], returning: [:id], on_conflict: :nothing)

Repo.insert_all("lms_points_ledger", [
  %{lms_account_id: lms_priya, transaction_type: "BASIC_EARNED",
    points_amount: Decimal.new("2200.00"), monetary_equiv: Decimal.new("22.00"),
    transaction_date: Date.add(today, -20), posting_date: Date.add(today, -19),
    expiry_date: Date.add(today, 365 * 2),
    warehouse_state: "ACTIVE", plan_id: plan_base, group_id: grp_default,
    scheme_id: scheme_id,
    idempotency_key: "SEED-PTS-PRIYA-EARN-001", inserted_at: now_utc},
  %{lms_account_id: lms_priya, transaction_type: "REDEEMED",
    points_amount: Decimal.new("-450.00"), monetary_equiv: Decimal.new("-4.50"),
    transaction_date: Date.add(today, -10), posting_date: Date.add(today, -10),
    warehouse_state: "HISTORY", scheme_id: scheme_id,
    idempotency_key: "SEED-PTS-PRIYA-REDEEM-001", inserted_at: now_utc},
  %{lms_account_id: lms_khalid, transaction_type: "BASIC_EARNED",
    points_amount: Decimal.new("7000.00"), monetary_equiv: Decimal.new("70.00"),
    transaction_date: Date.add(today, -12), posting_date: Date.add(today, -11),
    expiry_date: Date.add(today, 365 * 2),
    warehouse_state: "ACTIVE", plan_id: plan_base, group_id: grp_default,
    scheme_id: scheme_id, merchant_id: merch_rolex,
    idempotency_key: "SEED-PTS-KHALID-EARN-001", inserted_at: now_utc},
  %{lms_account_id: lms_khalid, transaction_type: "BONUS_EARNED",
    points_amount: Decimal.new("35000.00"), monetary_equiv: Decimal.new("350.00"),
    transaction_date: Date.add(today, -12), posting_date: Date.add(today, -11),
    expiry_date: Date.add(today, 365 * 2),
    warehouse_state: "ACTIVE", plan_id: plan_ovr, group_id: grp_dining,
    scheme_id: scheme_id, merchant_id: merch_rolex,
    idempotency_key: "SEED-PTS-KHALID-BONUS-001", inserted_at: now_utc},
  %{lms_account_id: lms_khalid, transaction_type: "REDEEMED",
    points_amount: Decimal.new("-2500.00"), monetary_equiv: Decimal.new("-25.00"),
    transaction_date: Date.add(today, -5), posting_date: Date.add(today, -5),
    warehouse_state: "HISTORY", scheme_id: scheme_id,
    idempotency_key: "SEED-PTS-KHALID-REDEEM-001", inserted_at: now_utc}
], on_conflict: :nothing)

Repo.insert_all("lms_redemptions", [
  %{lms_account_id: lms_priya, redemption_type: "ONLINE",
    points_redeemed: Decimal.new("450.00"), monetary_value: Decimal.new("4.50"),
    disbursement_method: "CREDIT", disbursement_date: Date.add(today, -10),
    status: "COMPLETED",
    idempotency_key: "SEED-REDEEM-PRIYA-001", inserted_at: now_utc},
  %{lms_account_id: lms_khalid, redemption_type: "AUTO_DISBURSEMENT",
    points_redeemed: Decimal.new("2500.00"), monetary_value: Decimal.new("25.00"),
    disbursement_method: "CREDIT", disbursement_date: Date.add(today, -5),
    status: "COMPLETED",
    idempotency_key: "SEED-REDEEM-KHALID-001", inserted_at: now_utc}
], on_conflict: :nothing)

IO.puts("    ✓ LMS scheme, 2 groups, 3 plans, 4 rate tiers, 2 enrolled accounts, 5 points entries, 2 redemptions")

# ============================================================
# PHASE 7 — HCS Hierarchy Company System
# ============================================================
IO.puts("--> Phase 7: HCS")

{2, [%{id: co_zaabi}, %{id: co_alfarsi}]} = Repo.insert_all("hcs_companies", [
  %{company_code: "ZAABI", company_name: "Zaabi Group LLC",
    registration_no: "REG-ABUDHABI-2015-001", tax_id: "TRN100123456700001",
    industry_code: "6412", liability_model: "CENTRAL", billing_cycle_day: 25,
    credit_limit: Decimal.new("500000.00"), available_limit: Decimal.new("497500.00"),
    max_employee_cards: 100, relationship_manager: "RM-CORP-001",
    status: "ACTIVE", kyc_status: "VERIFIED",
    kyc_verified_at: DateTime.add(now_utc, -180 * 86400),
    inserted_at: now_utc, updated_at: now_utc},
  %{company_code: "AFTR", company_name: "Al Farsi Trading Co",
    registration_no: "REG-DUBAI-2018-002", tax_id: "TRN100987654300001",
    industry_code: "5199", liability_model: "INDIVIDUAL", billing_cycle_day: 10,
    credit_limit: Decimal.new("100000.00"), available_limit: Decimal.new("100000.00"),
    max_employee_cards: 25, relationship_manager: "RM-CORP-002",
    status: "ACTIVE", kyc_status: "VERIFIED",
    kyc_verified_at: DateTime.add(now_utc, -90 * 86400),
    inserted_at: now_utc, updated_at: now_utc}
], returning: [:id], on_conflict: :nothing)

{2, [%{id: emp_rashid}, %{id: emp_fatima}]} = Repo.insert_all("hcs_employee_cards", [
  %{company_id: co_zaabi, employee_account_id: acc_rashid,
    employee_name: "Rashid Al Mulla", employee_id: "EMP-ZG-101",
    department: "Finance", cost_centre: "CC-FIN-001",
    individual_limit: Decimal.new("15000.00"),
    available_individual: Decimal.new("12500.00"),
    card_type: "PURCHASING", can_withdraw_cash: false,
    monthly_spend_cap: Decimal.new("12000.00"), status: "ACTIVE",
    issued_at: DateTime.add(now_utc, -60 * 86400),
    inserted_at: now_utc, updated_at: now_utc},
  %{company_id: co_zaabi, employee_account_id: acc_fatima,
    employee_name: "Fatima Al Khoori", employee_id: "EMP-ZG-102",
    department: "Operations", cost_centre: "CC-OPS-001",
    individual_limit: Decimal.new("10000.00"),
    available_individual: Decimal.new("9000.00"),
    card_type: "STANDARD", can_withdraw_cash: false,
    monthly_spend_cap: Decimal.new("8000.00"), status: "ACTIVE",
    issued_at: DateTime.add(now_utc, -60 * 86400),
    inserted_at: now_utc, updated_at: now_utc}
], returning: [:id], on_conflict: :nothing)

Repo.insert_all("hcs_spending_controls", [
  %{scope: "COMPANY", company_id: co_zaabi, control_type: "MCC_BLOCK",
    mcc_codes: ["7995", "9406", "6011"], channels: [],
    effective_from: ~D[2024-01-01], status: "ACTIVE", inserted_at: now_utc},
  %{scope: "COMPANY", company_id: co_zaabi, control_type: "DAILY_CAP",
    mcc_codes: [], channels: [],
    daily_cap: Decimal.new("50000.00"),
    effective_from: ~D[2024-01-01], status: "ACTIVE", inserted_at: now_utc},
  %{scope: "EMPLOYEE", company_id: co_zaabi, employee_card_id: emp_rashid,
    control_type: "TXN_CAP", mcc_codes: [], channels: [],
    per_txn_cap: Decimal.new("5000.00"),
    effective_from: ~D[2024-01-01], status: "ACTIVE", inserted_at: now_utc},
  %{scope: "EMPLOYEE", company_id: co_zaabi, employee_card_id: emp_fatima,
    control_type: "CHANNEL_BLOCK", mcc_codes: [], channels: ["ECOM", "CONTACTLESS"],
    effective_from: ~D[2024-01-01], status: "ACTIVE", inserted_at: now_utc}
], on_conflict: :nothing)

IO.puts("    ✓ 2 HCS companies, 2 employee cards, 4 spending controls")

# ============================================================
# PHASE 8 — ITS Interchange Tracking System
# ============================================================
IO.puts("--> Phase 8: ITS")

Repo.insert_all("its_copy_requests", [
  %{account_id: acc_priya, card_number_token: pan_priya,
    transaction_date: Date.add(today, -45),
    transaction_amount: Decimal.new("349.00"), currency: "AED",
    merchant_name: "XYZ Electronics", merchant_id: "MCHNT-00001",
    acquirer_bin: "400002", network: "MC",
    arn: "74123456789012345678901",
    request_type: "RETRIEVAL_REQUEST",
    request_reason: "Customer dispute: item not received",
    status: "SENT",
    sent_at: DateTime.add(now_utc, -40 * 86400),
    deadline_date: Date.add(today, 5),
    its1_batch_date: Date.add(today, -40),
    idempotency_key: "SEED-CR-PRIYA-001",
    inserted_at: now_utc, updated_at: now_utc},
  %{account_id: acc_mohammad, card_number_token: pan_mohammad,
    transaction_date: Date.add(today, -80),
    transaction_amount: Decimal.new("1500.00"), currency: "AED",
    merchant_name: "Furniture World", merchant_id: "MCHNT-00002",
    acquirer_bin: "524032", network: "MC",
    arn: "74987654321098765432109",
    request_type: "COPY_REQUEST",
    request_reason: "Chargeback supporting documentation",
    status: "FULFILLED",
    sent_at: DateTime.add(now_utc, -70 * 86400),
    fulfilled_at: DateTime.add(now_utc, -65 * 86400),
    response_reason: "Supporting documents received",
    deadline_date: Date.add(today, 50),
    its1_batch_date: Date.add(today, -70),
    its2_batch_date: Date.add(today, -65),
    idempotency_key: "SEED-CR-MOHAMMAD-001",
    inserted_at: now_utc, updated_at: now_utc},
  %{account_id: acc_ahmed, card_number_token: pan_ahmed,
    transaction_date: Date.add(today, -5),
    transaction_amount: Decimal.new("85.00"), currency: "AED",
    merchant_name: "ENOC Gas Station", merchant_id: "MCHNT-00003",
    acquirer_bin: "407200", network: "VI",
    request_type: "INQUIRY",
    request_reason: "Customer queried unrecognised charge",
    status: "PENDING",
    deadline_date: Date.add(today, 25),
    idempotency_key: "SEED-CR-AHMED-001",
    inserted_at: now_utc, updated_at: now_utc}
], on_conflict: :nothing)

Repo.insert_all("its_fee_claims", [
  %{network: "MC", claim_type: "INTERCHANGE_INCOME",
    mcc: "5411", interchange_category: "RETAIL",
    gross_amount: Decimal.new("450.00"),
    interchange_rate: Decimal.new("0.016500"),
    interchange_amount: Decimal.new("7.43"),
    scheme_fee_amount: Decimal.new("0.90"),
    net_interchange: Decimal.new("6.53"), currency: "AED",
    processing_date: Date.add(today, -13), settlement_date: Date.add(today, -11),
    status: "SETTLED",
    idempotency_key: "SEED-FEE-CR1", inserted_at: now_utc},
  %{network: "VI", claim_type: "INTERCHANGE_INCOME",
    mcc: "5943", interchange_category: "RETAIL",
    gross_amount: Decimal.new("3000.00"),
    interchange_rate: Decimal.new("0.016500"),
    interchange_amount: Decimal.new("49.50"),
    scheme_fee_amount: Decimal.new("4.50"),
    net_interchange: Decimal.new("45.00"), currency: "AED",
    processing_date: Date.add(today, -3), settlement_date: Date.add(today, -1),
    status: "PENDING",
    idempotency_key: "SEED-FEE-CR3", inserted_at: now_utc},
  %{network: "MC", claim_type: "INTERCHANGE_INCOME",
    mcc: "4511", interchange_category: "TRAVEL",
    gross_amount: Decimal.new("75000.00"),
    interchange_rate: Decimal.new("0.016500"),
    interchange_amount: Decimal.new("1237.50"),
    scheme_fee_amount: Decimal.new("75.00"),
    net_interchange: Decimal.new("1162.50"), currency: "AED",
    processing_date: Date.add(today, -6), settlement_date: Date.add(today, -4),
    status: "PENDING",
    idempotency_key: "SEED-FEE-CR4", inserted_at: now_utc}
], on_conflict: :nothing)

Repo.insert_all("its_financial_adjustments", [
  %{network: "MC", adjustment_type: "INTERCHANGE_CORRECTION",
    reference_no: "FAR-MC-2026-001234",
    original_txn_date: Date.add(today, -90),
    adjustment_amount: Decimal.new("-125.50"), currency: "AED",
    reason_code: "7030",
    reason_description: "Interchange rate correction — incorrect MCC applied",
    received_date: Date.add(today, -15), applied_date: Date.add(today, -14),
    status: "ACCEPTED",
    inserted_at: now_utc, updated_at: now_utc},
  %{network: "VI", adjustment_type: "MISROUTING",
    reference_no: "FAR-VI-2026-005678",
    original_txn_date: Date.add(today, -45),
    adjustment_amount: Decimal.new("89.00"), currency: "AED",
    reason_code: "2630",
    reason_description: "Transaction misrouted to incorrect acquirer",
    received_date: Date.add(today, -7),
    status: "UNDER_REVIEW",
    inserted_at: now_utc, updated_at: now_utc},
  %{network: "MC", adjustment_type: "PROCESSING_ERROR",
    reference_no: "FAR-MC-2026-009999",
    original_txn_date: Date.add(today, -20),
    adjustment_amount: Decimal.new("750.00"), currency: "AED",
    reason_code: "7031",
    reason_description: "Processing fee applied incorrectly",
    received_date: Date.add(today, -3),
    status: "RECEIVED",
    inserted_at: now_utc, updated_at: now_utc}
], on_conflict: :nothing)

IO.puts("    ✓ 3 copy requests, 3 fee claims, 3 FARs")
IO.puts("")
IO.puts("==> vMu seed complete.")
IO.puts("    Customers: 10  |  Accounts: 10  |  Disputes: 4")
IO.puts("    Clearing records: 6  |  Collection cases: 2")
IO.puts("    CDM applications: 4  |  Merchants: 4  |  Terminals: 5")
IO.puts("    LMS accounts: 2  |  Points entries: 5  |  Redemptions: 2")
IO.puts("    HCS companies: 2  |  Employee cards: 2  |  Spending controls: 4")
IO.puts("    ITS copy requests: 3  |  Fee claims: 3  |  FARs: 3")
