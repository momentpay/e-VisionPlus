# Phase 5 Implementation Spec — CDM Underwriting + ASM Portal + MBS Merchant

**Target:** Weeks 25–30  
**Outcome:** Full operator portal live (LiveView + FAPI 2.0). Credit underwriting decisions automated. Merchant billing active with MDR. Credit bureau reporting generated monthly.

---

## Task Overview

| # | Task | Module | Depends On |
|---|---|---|---|
| 26 | Credit underwriting rules engine + async bureau HTTP integration | vMu_cdm | T3 (accounts) |
| 27 | Cardholder web/mobile portal (Phoenix, separate from operator portal) | vMu_asm | T4, T11 |
| 28 | Operator portal — Phoenix LiveView + FAPI 2.0 mTLS plug | vMu_asm | T27 |
| 29 | MBS merchant hierarchy + MDR calculation engine + terminal management | vMu_mbs | T7 (GL) |
| 30 | Credit bureau reporting — Metro 2 format monthly file generator | vMu_cms | T11 (statements) |

---

## Task 26 — Credit Underwriting Rules Engine + Bureau Integration

CDM handles credit application processing: scoring applicants, calling credit bureaus, allocating a credit limit.

### Migration: `cdm_applications`
```sql
CREATE TABLE cdm_applications (
    application_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id         UUID        NOT NULL REFERENCES cms_customers(customer_id),
    sys_id              VARCHAR(4)  NOT NULL,
    bank_id             VARCHAR(4)  NOT NULL,
    logo_id             VARCHAR(4)  NOT NULL,
    block_id            VARCHAR(4)  NOT NULL,
    -- Applicant financial data
    monthly_income      DECIMAL(18,2),
    employment_status   VARCHAR(20),   -- EMPLOYED, SELF_EMPLOYED, RETIRED, UNEMPLOYED
    employer_name       VARCHAR(100),
    existing_liabilities DECIMAL(18,2),
    -- Bureau result
    bureau_score        INTEGER,
    bureau_ref          VARCHAR(64),
    bureau_checked_at   TIMESTAMP,
    -- Decision
    decision            VARCHAR(20),   -- APPROVED, DECLINED, REFERRED, PENDING
    approved_limit      DECIMAL(18,2),
    decline_reason      VARCHAR(50),
    decided_at          TIMESTAMP,
    -- Audit
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);
```

### Module: `lib/vmu_core/cdm/underwriting_engine.ex`
```elixir
defmodule VmuCore.CDM.UnderwritingEngine do
  @moduledoc """
  Credit underwriting pipeline:
    1. Basic eligibility check (age, income threshold)
    2. Async bureau call (Oban job — never block the HTTP request)
    3. Score-based limit allocation
    4. Policy rules (DSR cap, maximum limit by tier)
  """

  alias VmuCore.{Repo, CDM.Application, Shared.ParameterEngine}

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Submit a credit application for underwriting. Returns {:ok, application_id}."
  def submit(customer_id, sys_id, bank_id, logo_id, block_id, attrs) do
    Repo.transaction(fn ->
      app = Repo.insert!(%Application{
        customer_id: customer_id, sys_id: sys_id, bank_id: bank_id,
        logo_id: logo_id, block_id: block_id, decision: "PENDING",
        monthly_income: attrs.monthly_income,
        employment_status: attrs.employment_status,
        existing_liabilities: Map.get(attrs, :existing_liabilities, Decimal.new("0"))
      })

      # Enqueue async bureau check — never hold the caller
      %{"application_id" => app.application_id}
      |> VmuCore.CDM.BureauCheckJob.new()
      |> Oban.insert!()

      {:ok, app.application_id}
    end)
  end

  @doc "Called by BureauCheckJob after bureau result arrives."
  def decide(application_id, bureau_score, bureau_ref) do
    app = Repo.get!(Application, application_id)

    Repo.update_all(
      from(a in Application, where: a.application_id == ^application_id),
      set: [bureau_score: bureau_score, bureau_ref: bureau_ref, bureau_checked_at: DateTime.utc_now()]
    )

    with {:ok, limit} <- allocate_limit(app, bureau_score),
         :ok          <- check_policy(app, limit) do
      Repo.update_all(
        from(a in Application, where: a.application_id == ^application_id),
        set: [decision: "APPROVED", approved_limit: limit, decided_at: DateTime.utc_now()]
      )
      {:approved, limit}
    else
      {:declined, reason} ->
        Repo.update_all(
          from(a in Application, where: a.application_id == ^application_id),
          set: [decision: "DECLINED", decline_reason: reason, decided_at: DateTime.utc_now()]
        )
        {:declined, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring and policy
  # ---------------------------------------------------------------------------

  defp allocate_limit(app, bureau_score) do
    # Income multiplier by score band — load from block_parameters
    multiplier = case bureau_score do
      score when score >= 750 -> Decimal.new("6")    # 6× monthly income
      score when score >= 700 -> Decimal.new("4")
      score when score >= 650 -> Decimal.new("2")
      score when score >= 600 -> Decimal.new("1")
      _                       -> nil
    end

    if multiplier do
      proposed = Decimal.mult(app.monthly_income, multiplier)
      {:ok, proposed}
    else
      {:declined, "SCORE_TOO_LOW"}
    end
  end

  defp check_policy(app, proposed_limit) do
    # DSR (Debt Service Ratio) cap: (existing_liabilities + new_payment) / income ≤ 50%
    estimated_payment = Decimal.mult(proposed_limit, Decimal.new("0.03"))  # assume 3% min payment
    total_obligations = Decimal.add(app.existing_liabilities, estimated_payment)
    dsr = Decimal.div(total_obligations, app.monthly_income)

    if Decimal.compare(dsr, Decimal.new("0.5")) == :gt do
      {:declined, "DSR_EXCEEDED"}
    else
      :ok
    end
  end
end
```

### Bureau Integration (Oban async job):
```elixir
defmodule VmuCore.CDM.BureauCheckJob do
  use Oban.Worker, queue: :bureau, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"application_id" => application_id}}) do
    # Call external credit bureau (Al Etihad Credit Bureau for UAE, etc.)
    case call_bureau(application_id) do
      {:ok, %{score: score, ref: ref}} ->
        VmuCore.CDM.UnderwritingEngine.decide(application_id, score, ref)
        :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp call_bureau(application_id) do
    app = VmuCore.Repo.get!(VmuCore.CDM.Application, application_id)
    customer = VmuCore.Repo.get!(VmuCore.Shared.Customer, app.customer_id)

    # HTTP call to bureau API — Req with timeout and retry
    Req.post("https://bureau.example.com/api/score",
      json: %{id_number: customer.id_number, id_type: customer.id_type},
      headers: [{"Authorization", "Bearer #{bureau_token()}"}],
      receive_timeout: 10_000
    )
    |> case do
      {:ok, %{status: 200, body: %{"score" => score, "ref" => ref}}} ->
        {:ok, %{score: score, ref: ref}}
      {:ok, %{status: status}} ->
        {:error, {:bureau_http_error, status}}
      {:error, reason} ->
        {:error, {:bureau_connection_error, reason}}
    end
  end

  defp bureau_token, do: Application.fetch_env!(:vmu_core, :bureau_api_token)
end
```

---

## Task 27 — Cardholder Web/Mobile Portal

Separate from the operator portal. Cardholders authenticate and self-serve: view statements, pay, manage limits, view transactions.

```elixir
# lib/vmu_core_web/controllers/cardholder/auth_controller.ex
defmodule VmuCoreWeb.Cardholder.AuthController do
  use VmuCoreWeb, :controller

  @doc "Authenticate cardholder with account + OTP."
  def login(conn, %{"account_token" => token, "otp" => otp}) do
    with {:ok, account_id} <- resolve_account_from_token(token),
         :ok               <- VmuCore.ITS.OtpEngine.verify(account_id, otp),
         {:ok, session}    <- create_session(account_id) do
      conn
      |> put_session(:cardholder_session, session.token)
      |> json(%{status: "ok", session_token: session.token})
    else
      {:error, reason} ->
        conn |> put_status(401) |> json(%{error: "#{reason}"})
    end
  end

  defp resolve_account_from_token(token) do
    case VmuCore.Repo.get_by(VmuCore.CMS.Account, pan_token: token) do
      nil -> {:error, :account_not_found}
      acc -> {:ok, acc.account_id}
    end
  end

  defp create_session(account_id) do
    token = :crypto.strong_rand_bytes(32) |> Base.url_encode64()
    {:ok, %{token: token, account_id: account_id}}
  end
end
```

### Key cardholder portal routes:
```elixir
# lib/vmu_core_web/router.ex (cardholder scope)
scope "/cardholder", VmuCoreWeb.Cardholder do
  pipe_through [:api, :cardholder_auth]

  get  "/accounts/:id/balance",      AccountController, :balance
  get  "/accounts/:id/transactions", AccountController, :transactions
  get  "/accounts/:id/statements",   AccountController, :statements
  post "/accounts/:id/payment",      PaymentController, :create
  put  "/accounts/:id/limits",       LimitController,   :update
  post "/accounts/:id/block",        CardController,    :block
  post "/accounts/:id/activate",     CardController,    :activate
  post "/otp/send",                  OtpController,     :send
  post "/otp/verify",                OtpController,     :verify
end
```

---

## Task 28 — Operator Portal (Phoenix LiveView + FAPI 2.0)

The operator portal is used by bank staff. It requires stronger authentication (FAPI 2.0: mTLS + JWT) than the cardholder portal.

### FAPI 2.0 Plug (`lib/vmu_core_web/plugs/fapi_validation_plug.ex`):
```elixir
defmodule VmuCoreWeb.Plugs.FapiValidationPlug do
  @moduledoc """
  FAPI 2.0 (Financial-grade API) security validation:
    1. Mutual TLS (mTLS) — verify client certificate against CA
    2. JWT Bearer token — signed with RS256, audience = vmu_asm
    3. DPoP proof (optional, for sender-constrained tokens)
    4. Verify certificate thumbprint in JWT matches presented cert
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with {:ok, cert}   <- extract_client_cert(conn),
         {:ok, jwt}    <- extract_bearer_token(conn),
         {:ok, claims} <- verify_jwt(jwt),
         :ok           <- verify_cert_binding(cert, claims) do
      assign(conn, :operator, %{
        id:    claims["sub"],
        roles: claims["roles"],
        bank:  claims["bank_id"]
      })
    else
      {:error, reason} ->
        Logger.warn("[FAPI] Auth failed: #{inspect(reason)}")
        conn |> send_resp(401, "Unauthorized") |> halt()
    end
  end

  defp extract_client_cert(conn) do
    case get_req_header(conn, "x-ssl-client-cert") do
      [cert_pem] -> X509.Certificate.from_pem(cert_pem)
      []         -> {:error, :no_client_cert}
    end
  end

  defp extract_bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] -> {:ok, token}
      _                    -> {:error, :no_bearer_token}
    end
  end

  defp verify_jwt(token) do
    public_key = Application.fetch_env!(:vmu_core, :fapi_public_key)
    JOSE.JWT.verify_strict(public_key, ["RS256"], token)
    |> case do
      {true, %JOSE.JWT{fields: claims}, _} -> {:ok, claims}
      {false, _, _}                        -> {:error, :invalid_jwt}
    end
  end

  defp verify_cert_binding(cert, claims) do
    # FAPI 2.0: JWT must contain cnf.x5t#S256 = SHA-256 thumbprint of the client cert
    expected_thumbprint = cert |> X509.Certificate.to_der() |> thumbprint_sha256()
    case get_in(claims, ["cnf", "x5t#S256"]) do
      ^expected_thumbprint -> :ok
      _                   -> {:error, :cert_binding_mismatch}
    end
  end

  defp thumbprint_sha256(der), do: :crypto.hash(:sha256, der) |> Base.url_encode64(padding: false)
end
```

### Operator portal LiveView pages:
```elixir
# Key LiveView modules to build:
# VmuCoreWeb.Operator.AccountLive      — account search, status, balance view
# VmuCoreWeb.Operator.CardLive         — card management (block, replace, limits)
# VmuCoreWeb.Operator.DisputeLive      — dispute queue and workflow actions
# VmuCoreWeb.Operator.CollectionLive   — collection cases by DPD bucket
# VmuCoreWeb.Operator.ParameterLive    — SYS/BANK/LOGO/BLOCK parameter management
# VmuCoreWeb.Operator.ReportLive       — EOD and operational reports

scope "/operator", VmuCoreWeb.Operator do
  pipe_through [:browser, :fapi_auth]

  live "/accounts",            AccountLive, :index
  live "/accounts/:id",        AccountLive, :show
  live "/cards/:id",           CardLive, :show
  live "/disputes",            DisputeLive, :index
  live "/disputes/:id",        DisputeLive, :show
  live "/collections",         CollectionLive, :index
  live "/parameters",          ParameterLive, :index
  live "/reports",             ReportLive, :index
end
```

---

## Task 29 — MBS Merchant Hierarchy + MDR Calculation + Terminal Management

MBS manages the acquiring side: merchants, terminals, MDR fees, and settlement to merchants.

### Migration: `mbs_merchants` + `mbs_terminals`
```sql
CREATE TABLE mbs_merchants (
    merchant_id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sys_id              VARCHAR(4)  NOT NULL,
    bank_id             VARCHAR(4)  NOT NULL,
    merchant_name       VARCHAR(100) NOT NULL,
    merchant_category   VARCHAR(50),
    mcc                 VARCHAR(4),
    -- MDR contract
    mdr_rate_id         UUID,                   -- references mdr_rates from settlement_core
    pricing_model       VARCHAR(20) NOT NULL DEFAULT 'FLAT',  -- FLAT, TIERED, INTERCHANGE_PLUS
    interchange_plus    DECIMAL(5,4),           -- basis points above interchange (if IC+)
    -- Settlement
    settlement_account  VARCHAR(34),            -- IBAN for settlement
    settlement_cycle    VARCHAR(10) NOT NULL DEFAULT 'T+1',
    status              VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);

CREATE TABLE mbs_terminals (
    terminal_id         VARCHAR(8)  PRIMARY KEY,   -- matches DE41 in ISO 8583
    merchant_id         UUID        NOT NULL REFERENCES mbs_merchants(merchant_id),
    terminal_type       VARCHAR(10) NOT NULL,       -- POS, ATM, MPOS, VPOS
    model               VARCHAR(50),
    serial_number       VARCHAR(50),
    status              VARCHAR(10) NOT NULL DEFAULT 'ACTIVE',
    last_key_exchange   TIMESTAMP,
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);
```

### MDR Calculation Engine:
```elixir
defmodule VmuCore.MBS.MdrEngine do
  @moduledoc """
  Calculates Merchant Discount Rate (MDR) for a transaction.
  Reuses SettlementCore.InterchangeRate from settlement_core (existing).
  """

  alias VmuCore.{Repo, MBS.Merchant}
  alias SettlementCore.InterchangeRate

  @doc "Calculate MDR for a merchant transaction."
  def calculate(merchant_id, transaction_amount, mcc, network) do
    merchant = Repo.get!(Merchant, merchant_id)

    interchange = InterchangeRate.lookup(mcc, network, transaction_amount)

    case merchant.pricing_model do
      "FLAT" ->
        # Flat rate from mdr_rates table
        flat_rate = get_flat_rate(merchant.mdr_rate_id, mcc)
        mdr = Decimal.mult(transaction_amount, Decimal.div(flat_rate, Decimal.new("100")))
        {:ok, %{mdr: mdr, interchange: interchange, net_to_merchant: Decimal.sub(transaction_amount, mdr)}}

      "INTERCHANGE_PLUS" ->
        # Interchange + basis points
        plus_rate = merchant.interchange_plus || Decimal.new("0.005")
        total_rate = Decimal.add(interchange.rate, plus_rate)
        mdr = Decimal.mult(transaction_amount, total_rate)
        {:ok, %{mdr: mdr, interchange: interchange.amount, net_to_merchant: Decimal.sub(transaction_amount, mdr)}}
    end
  end

  defp get_flat_rate(mdr_rate_id, _mcc) do
    case VmuCore.Repo.get(SettlementCore.MdrRate, mdr_rate_id) do
      nil  -> Decimal.new("1.5")  # default 1.5%
      rate -> rate.rate_percentage
    end
  end
end
```

---

## Task 30 — Credit Bureau Reporting (Metro 2 Format)

Monthly regulatory obligation. Generates a Metro 2 format file reporting account status to credit bureaus.

### Metro 2 Base Segment (key fields):
```
Field  Length  Description
1      4       Record descriptor word
2      2       Processing indicator
3      5       Timestamp (MMDDYYYY format)
4      1       Reserved
5      20      Account number (PAN token / masked)
6      2       Portfolio type (R=Revolving, I=Installment)
7      1       Account type
8      8       Date opened (MMDDYYYY)
9      9       Credit limit
10     9       Highest credit
11     2       Terms duration
12     2       Terms frequency
13     9       Scheduled monthly payment
14     9       Actual payment amount
15     2       Account status (see below)
16     2       Payment rating
17     5       Payment history profile (24 months)
...
```

### Account Status Codes (Metro 2):
```
11 = Current account (0 DPD, paid as agreed)
71 = 30-59 DPD
78 = 60-89 DPD
80 = 90-119 DPD
82 = 120-149 DPD
97 = Written off as bad debt (charge-off)
```

### Generator:
```elixir
defmodule VmuCore.CMS.CreditBureauReporter do
  @moduledoc """
  Generates Metro 2 format credit bureau reporting file.
  One record per active credit account.
  Run monthly via Oban cron on the 1st of each month.
  """

  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.Statement}

  def generate(reporting_date \\ Date.utc_today()) do
    accounts = Repo.all(
      from a in Account,
        where: a.account_status in ["ACTIVE", "DELINQUENT", "WRITTEN_OFF"],
        preload: [:balance_bucket]
    )

    header  = build_header(reporting_date, length(accounts))
    records = Enum.map(accounts, &build_base_segment(&1, reporting_date))
    trailer = build_trailer(length(accounts))

    content = [header | records] ++ [trailer] |> Enum.join("")
    file_name = "metro2_#{Date.to_iso8601(reporting_date)}.txt"
    File.write!(file_name, content)
    {:ok, file_name}
  end

  defp build_base_segment(account, reporting_date) do
    status_code = dpd_to_metro2_status(account.delinquency_bucket, account.account_status)
    payment_history = build_24_month_history(account.account_id, reporting_date)
    credit_limit = account.credit_limit |> Decimal.to_integer() |> Integer.to_string() |> String.pad_leading(9, "0")
    high_balance = get_high_balance(account.account_id) |> Decimal.to_integer() |> Integer.to_string() |> String.pad_leading(9, "0")

    # Metro 2 Base Segment — fixed-width 426 bytes total
    # This is a simplified representation; full spec has 50+ fields
    [
      "0426",                                          # record descriptor (4)
      "DA",                                            # portfolio type: revolving (2)
      format_date(account.open_date),                  # date opened (8)
      credit_limit,                                    # credit limit (9)
      high_balance,                                    # highest credit (9)
      status_code,                                     # account status (2)
      payment_history,                                 # 24-month history (24)
      format_date(reporting_date)                      # date of account information (8)
    ]
    |> Enum.join("")
  end

  defp dpd_to_metro2_status(dpd, "WRITTEN_OFF"), do: "97"
  defp dpd_to_metro2_status(0, _),   do: "11"
  defp dpd_to_metro2_status(30, _),  do: "71"
  defp dpd_to_metro2_status(60, _),  do: "78"
  defp dpd_to_metro2_status(90, _),  do: "80"
  defp dpd_to_metro2_status(120, _), do: "82"
  defp dpd_to_metro2_status(_, _),   do: "82"

  defp build_24_month_history(account_id, reporting_date) do
    # Retrieve DPD bucket for each of past 24 months from statements table
    months = for i <- 0..23, do: Date.add(reporting_date, -(i * 30))

    months
    |> Enum.map(fn month ->
      statement = Repo.one(
        from s in Statement,
          where: s.account_id == ^account_id
            and s.statement_date <= ^month,
          order_by: [desc: s.statement_date],
          limit: 1
      )
      case statement do
        nil -> "X"
        s   -> dpd_to_payment_code(s.delinquency_bucket_at_statement)
      end
    end)
    |> Enum.join("")
  end

  defp dpd_to_payment_code(nil), do: "C"  # current
  defp dpd_to_payment_code(0),   do: "C"
  defp dpd_to_payment_code(30),  do: "1"
  defp dpd_to_payment_code(60),  do: "2"
  defp dpd_to_payment_code(90),  do: "3"
  defp dpd_to_payment_code(_),   do: "4"

  defp format_date(nil), do: "00000000"
  defp format_date(%Date{} = d) do
    "#{String.pad_leading("#{d.month}", 2, "0")}#{String.pad_leading("#{d.day}", 2, "0")}#{d.year}"
  end

  defp get_high_balance(account_id) do
    Repo.one(from s in Statement, where: s.account_id == ^account_id, select: max(s.closing_balance)) || Decimal.new("0")
  end

  defp build_header(date, count) do
    "HEADER#{Date.to_iso8601(date)}#{String.pad_leading("#{count}", 10, "0")}"
  end

  defp build_trailer(count) do
    "TRAILER#{String.pad_leading("#{count}", 10, "0")}"
  end
end
```

### Oban cron for monthly bureau reporting:
```elixir
# Add to Oban cron config:
{"0 6 1 * *", VmuCore.CMS.BureauReportJob}   # 06:00 on 1st of every month
```

---

## Phase 5 Done Criteria

- [ ] `UnderwritingEngine.submit/6` creates an application in PENDING state and enqueues a BureauCheckJob
- [ ] `BureauCheckJob.perform/1` calls the configured bureau API, receives a score, and calls `decide/3`
- [ ] `UnderwritingEngine.decide/3` approves with correct limit (6× income for score ≥ 750) or declines on DSR > 50%
- [ ] Cardholder portal `/cardholder/accounts/:id/balance` returns OTB and bucket balances after JWT auth
- [ ] Cardholder portal OTP flow: `POST /otp/send` → `POST /otp/verify` → session created
- [ ] FAPI 2.0 plug rejects requests without client cert with 401
- [ ] FAPI 2.0 plug rejects JWTs where `cnf.x5t#S256` does not match presented cert thumbprint
- [ ] Operator portal LiveView account search renders account list from DB
- [ ] `MdrEngine.calculate/4` returns correct MDR for FLAT pricing model and INTERCHANGE_PLUS model
- [ ] `CreditBureauReporter.generate/1` produces a file where each line is 426+ bytes with correct status codes
- [ ] Accounts with 30 DPD have Metro 2 status "71"; WRITTEN_OFF accounts have "97"
- [ ] Bureau report Oban job scheduled for 1st of month at 06:00
