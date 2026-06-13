# Phase 7 — HCS Hierarchy Company System
## Implementation Specification

**Repository:** `vmu_core`  
**Module namespace:** `VmuCore.HCS`  
**VisionPlus reference:** HCS — Commercial Card Processing (learnpaymentcard.wordpress.com)  
**Status:** PLANNED — implement when commercial/corporate card launch confirmed  
**Prerequisite:** Phase 6 (LMS) complete; CMS account hierarchy must be extendable

---

## 1. Overview

HCS (Hierarchy Company System) supports **commercial and corporate card programmes** where a corporate entity (Hierarchy Company) controls cards issued to employees. Key capabilities:

- Corporate parent account with a company credit limit
- Employee cards each having individual sub-limits within the parent pool
- Two liability models: **Central Liability** (company pays) and **Individual Liability** (employee pays, company guarantees)
- Consolidated billing statement at company level
- Company-level spending controls cascading to employee cards
- Inter-account payment sweep (collect from employee accounts, pay parent)
- Separate KYC/onboarding flow for corporate entities

---

## 2. Structural Hierarchy

```
HCS Company (Corporate Entity)
  └── Parent Account (cms_accounts, account_type = 'CORPORATE_PARENT')
        └── Employee Card Account 1 (cms_accounts, account_type = 'EMPLOYEE_CARD')
        └── Employee Card Account 2
        └── Employee Card Account N
              ↑ Each employee card has an individual sub-limit
              ↑ All share the parent company's credit pool
```

---

## 3. Database Schema

### 3.1 `hcs_companies`

```sql
CREATE TABLE hcs_companies (
  id                  BIGSERIAL PRIMARY KEY,
  company_code        VARCHAR(20)    NOT NULL UNIQUE,
  company_name        VARCHAR(200)   NOT NULL,
  registration_no     VARCHAR(50)    NOT NULL,         -- trade licence / CR number
  tax_id              VARCHAR(50),
  industry_code       VARCHAR(10),                     -- MCC-style industry classification
  liability_model     VARCHAR(20)    NOT NULL,          -- 'CENTRAL' | 'INDIVIDUAL'
  billing_cycle_day   INTEGER        NOT NULL DEFAULT 25,
  credit_limit        NUMERIC(18,2)  NOT NULL,          -- total company credit pool
  available_limit     NUMERIC(18,2)  NOT NULL,          -- real-time; decremented by employee usage
  max_employee_cards  INTEGER        NOT NULL DEFAULT 50,
  parent_account_id   BIGINT         REFERENCES cms_accounts(id),  -- master billing account
  relationship_manager VARCHAR(100),
  status              VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  kyc_status          VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
  kyc_verified_at     TIMESTAMPTZ,
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX hcs_companies_status ON hcs_companies(status);
```

### 3.2 `hcs_employee_cards`

```sql
CREATE TABLE hcs_employee_cards (
  id                  BIGSERIAL PRIMARY KEY,
  company_id          BIGINT         NOT NULL REFERENCES hcs_companies(id),
  employee_account_id BIGINT         NOT NULL REFERENCES cms_accounts(id),
  employee_name       VARCHAR(200)   NOT NULL,
  employee_id         VARCHAR(50),                     -- HR employee reference
  department          VARCHAR(100),
  cost_centre         VARCHAR(50),
  individual_limit    NUMERIC(18,2)  NOT NULL,          -- sub-limit within company pool
  available_individual NUMERIC(18,2) NOT NULL,          -- real-time sub-limit balance
  card_type           VARCHAR(20)    NOT NULL DEFAULT 'STANDARD',
    -- 'STANDARD' | 'TRAVEL' | 'PURCHASING' | 'VIRTUAL'
  can_withdraw_cash   BOOLEAN        NOT NULL DEFAULT FALSE,
  monthly_spend_cap   NUMERIC(18,2),                   -- NULL = no cap beyond individual_limit
  status              VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  issued_at           TIMESTAMPTZ,
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE(company_id, employee_account_id)
);

CREATE INDEX hcs_employee_cards_company ON hcs_employee_cards(company_id, status);
CREATE INDEX hcs_employee_cards_account ON hcs_employee_cards(employee_account_id);
```

### 3.3 `hcs_spending_controls`

Per-employee or per-company spending restriction rules (merchant category, channel, time, amount).

```sql
CREATE TABLE hcs_spending_controls (
  id              BIGSERIAL PRIMARY KEY,
  scope           VARCHAR(15)    NOT NULL,              -- 'COMPANY' | 'EMPLOYEE'
  company_id      BIGINT         NOT NULL REFERENCES hcs_companies(id),
  employee_card_id BIGINT        REFERENCES hcs_employee_cards(id),  -- NULL = company-wide
  control_type    VARCHAR(30)    NOT NULL,
    -- 'MCC_BLOCK' | 'MCC_ALLOW' | 'CHANNEL_BLOCK' | 'DAILY_CAP' | 'TXN_CAP'
  mcc_codes       VARCHAR[]      DEFAULT '{}',          -- for MCC_BLOCK / MCC_ALLOW
  channels        VARCHAR[]      DEFAULT '{}',          -- e.g., ['ATM', 'ECOMMERCE']
  daily_cap       NUMERIC(18,2),
  per_txn_cap     NUMERIC(18,2),
  effective_from  DATE           NOT NULL,
  effective_to    DATE,
  status          VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  inserted_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX hcs_spending_controls_scope ON hcs_spending_controls(company_id, scope, status);
```

### 3.4 `hcs_consolidated_statements`

```sql
CREATE TABLE hcs_consolidated_statements (
  id              BIGSERIAL PRIMARY KEY,
  company_id      BIGINT         NOT NULL REFERENCES hcs_companies(id),
  statement_date  DATE           NOT NULL,
  period_from     DATE           NOT NULL,
  period_to       DATE           NOT NULL,
  total_spend     NUMERIC(18,2)  NOT NULL DEFAULT 0,
  total_payments  NUMERIC(18,2)  NOT NULL DEFAULT 0,
  total_fees      NUMERIC(18,2)  NOT NULL DEFAULT 0,
  total_interest  NUMERIC(18,2)  NOT NULL DEFAULT 0,
  closing_balance NUMERIC(18,2)  NOT NULL DEFAULT 0,
  minimum_payment NUMERIC(18,2)  NOT NULL DEFAULT 0,
  payment_due_date DATE          NOT NULL,
  employee_count  INTEGER        NOT NULL DEFAULT 0,    -- active cards in this statement
  file_path       VARCHAR(500),                         -- SFTP path to statement PDF/file
  status          VARCHAR(20)    NOT NULL DEFAULT 'GENERATED',
  inserted_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE(company_id, statement_date)
);
```

### 3.5 `hcs_payment_sweeps`

When central liability is used, the system sweeps balances from employee accounts to the parent account.

```sql
CREATE TABLE hcs_payment_sweeps (
  id                  BIGSERIAL PRIMARY KEY,
  company_id          BIGINT         NOT NULL REFERENCES hcs_companies(id),
  sweep_date          DATE           NOT NULL,
  total_swept         NUMERIC(18,2)  NOT NULL DEFAULT 0,
  employee_card_count INTEGER        NOT NULL DEFAULT 0,
  status              VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
    -- 'PENDING' | 'COMPLETED' | 'PARTIAL' | 'FAILED'
  gl_entry_id         BIGINT,
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE TABLE hcs_payment_sweep_lines (
  id                  BIGSERIAL PRIMARY KEY,
  sweep_id            BIGINT         NOT NULL REFERENCES hcs_payment_sweeps(id),
  employee_card_id    BIGINT         NOT NULL REFERENCES hcs_employee_cards(id),
  swept_amount        NUMERIC(18,2)  NOT NULL,
  status              VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
```

---

## 4. Elixir Modules

### 4.1 `VmuCore.HCS.LimitController`

Dual-layer limit enforcement: employee sub-limit checked first, then company pool.

```elixir
defmodule VmuCore.HCS.LimitController do
  alias VmuCore.HCS.{Company, EmployeeCard}
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Called from AccountStateCoordinator.do_authorize/4 for EMPLOYEE_CARD accounts.
  Checks:
  1. Employee individual_limit (available_individual >= amount)
  2. Company available_limit (company pool >= amount)
  3. Spending controls (MCC block, channel block, per-txn cap, daily cap)
  Returns :ok | {:error, reason}
  """
  def check_hcs_limits(employee_account_id, amount, channel, mcc) do
    case get_employee_card(employee_account_id) do
      nil ->
        :ok  # Not an HCS card; skip HCS checks

      employee_card ->
        company = Repo.get!(Company, employee_card.company_id)

        with :ok <- check_company_active(company),
             :ok <- check_individual_limit(employee_card, amount),
             :ok <- check_company_pool(company, amount),
             :ok <- check_spending_controls(company.id, employee_card.id, amount, channel, mcc) do
          :ok
        end
    end
  end

  defp get_employee_card(employee_account_id) do
    Repo.one(
      from ec in EmployeeCard,
      where: ec.employee_account_id == ^employee_account_id and ec.status == "ACTIVE"
    )
  end

  defp check_company_active(%{status: "ACTIVE"}), do: :ok
  defp check_company_active(_), do: {:error, :company_suspended}

  defp check_individual_limit(%{available_individual: avail}, amount) do
    if D.lt?(avail, D.new(amount)) do
      {:error, :individual_limit_exceeded}
    else
      :ok
    end
  end

  defp check_company_pool(%{available_limit: avail}, amount) do
    if D.lt?(avail, D.new(amount)) do
      {:error, :company_pool_exhausted}
    else
      :ok
    end
  end

  defp check_spending_controls(company_id, employee_card_id, amount, channel, mcc) do
    controls = get_active_controls(company_id, employee_card_id)

    Enum.reduce_while(controls, :ok, fn control, :ok ->
      case apply_control(control, amount, channel, mcc) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp get_active_controls(company_id, employee_card_id) do
    Repo.all(
      from c in VmuCore.HCS.SpendingControl,
      where: c.company_id == ^company_id
        and c.status == "ACTIVE"
        and (is_nil(c.employee_card_id) or c.employee_card_id == ^employee_card_id)
        and c.effective_from <= ^Date.utc_today()
        and (is_nil(c.effective_to) or c.effective_to >= ^Date.utc_today())
    )
  end

  defp apply_control(%{control_type: "MCC_BLOCK", mcc_codes: codes}, _amount, _channel, mcc) do
    if mcc in codes, do: {:error, :mcc_blocked}, else: :ok
  end
  defp apply_control(%{control_type: "MCC_ALLOW", mcc_codes: codes}, _amount, _channel, mcc) do
    if mcc in codes, do: :ok, else: {:error, :mcc_not_allowed}
  end
  defp apply_control(%{control_type: "CHANNEL_BLOCK", channels: blocked}, _amount, channel, _mcc) do
    if channel in blocked, do: {:error, :channel_blocked}, else: :ok
  end
  defp apply_control(%{control_type: "TXN_CAP", per_txn_cap: cap}, amount, _channel, _mcc) when not is_nil(cap) do
    if D.gt?(D.new(amount), cap), do: {:error, :per_txn_cap_exceeded}, else: :ok
  end
  defp apply_control(_, _, _, _), do: :ok

  @doc """
  Decrements both the employee individual_limit and company pool after authorization.
  Called from AccountStateCoordinator after a successful authorize.
  """
  def debit_limits(employee_account_id, amount) do
    dec = D.new(amount)

    Repo.transaction(fn ->
      employee_card = get_employee_card(employee_account_id)

      if employee_card do
        Repo.update_all(
          from(ec in EmployeeCard, where: ec.id == ^employee_card.id),
          inc: [available_individual: D.negate(dec)]
        )

        Repo.update_all(
          from(c in Company, where: c.id == ^employee_card.company_id),
          inc: [available_limit: D.negate(dec)]
        )
      end
    end)
  end

  @doc """
  Restores limits on payment or reversal.
  """
  def credit_limits(employee_account_id, amount) do
    inc = D.new(amount)

    employee_card = get_employee_card(employee_account_id)
    if employee_card do
      Repo.update_all(
        from(ec in EmployeeCard, where: ec.id == ^employee_card.id),
        inc: [available_individual: inc]
      )
      Repo.update_all(
        from(c in Company, where: c.id == ^employee_card.company_id),
        inc: [available_limit: inc]
      )
    end
  end
end
```

### 4.2 `VmuCore.HCS.ConsolidatedStatementGenerator`

```elixir
defmodule VmuCore.HCS.ConsolidatedStatementGenerator do
  alias VmuCore.HCS.{Company, EmployeeCard, ConsolidatedStatement}
  alias VmuCore.CMS.{Account, LedgerEntry}
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Generates a consolidated statement for all active HCS companies.
  Called from the EOD GenerateStatementJob for accounts with billing_cycle_day = today.
  """
  def generate_for_date(statement_date) do
    companies =
      from(c in Company,
        where: c.status == "ACTIVE"
          and c.billing_cycle_day == ^statement_date.day
      )
      |> Repo.all()

    Enum.each(companies, &generate_company_statement(&1, statement_date))
  end

  defp generate_company_statement(company, statement_date) do
    period_to = statement_date
    period_from = Date.add(statement_date, -30)  # approximate; use actual cycle dates

    # Fetch all employee account IDs under this company
    employee_account_ids =
      from(ec in EmployeeCard,
        where: ec.company_id == ^company.id and ec.status == "ACTIVE",
        select: ec.employee_account_id
      )
      |> Repo.all()

    # Aggregate spend/payments/fees/interest across all employee accounts
    totals = aggregate_period_activity(employee_account_ids, period_from, period_to)

    closing_balance =
      from(a in Account,
        where: a.id in ^employee_account_ids,
        select: sum(a.current_balance)
      )
      |> Repo.one()
      |> Kernel.||(D.new(0))

    minimum_payment = D.max(
      D.mult(closing_balance, D.new("0.05")),
      D.new(100)
    )

    %ConsolidatedStatement{}
    |> ConsolidatedStatement.changeset(%{
      company_id:      company.id,
      statement_date:  statement_date,
      period_from:     period_from,
      period_to:       period_to,
      total_spend:     totals.spend,
      total_payments:  totals.payments,
      total_fees:      totals.fees,
      total_interest:  totals.interest,
      closing_balance: closing_balance,
      minimum_payment: minimum_payment,
      payment_due_date: Date.add(statement_date, 25),
      employee_count:  length(employee_account_ids),
      status:          "GENERATED"
    })
    |> Repo.insert(on_conflict: [set: [status: "GENERATED"]], conflict_target: [:company_id, :statement_date])
  end

  defp aggregate_period_activity(account_ids, period_from, period_to) do
    entries =
      from(l in LedgerEntry,
        where: l.account_id in ^account_ids
          and l.inserted_at >= ^DateTime.new!(period_from, ~T[00:00:00])
          and l.inserted_at <= ^DateTime.new!(period_to, ~T[23:59:59]),
        select: %{
          debit_total:   sum(l.debit_amount),
          credit_total:  sum(l.credit_amount)
        }
      )
      |> Repo.one()

    %{
      spend:    entries[:debit_total] || D.new(0),
      payments: entries[:credit_total] || D.new(0),
      fees:     D.new(0),      # TODO: join fee_entries when fee ledger codes are typed
      interest: D.new(0)       # TODO: join interest entries
    }
  end
end
```

### 4.3 `VmuCore.HCS.PaymentSweepJob` (Oban)

For Central Liability companies — sweeps balances from all employee accounts to the parent billing account nightly.

```elixir
defmodule VmuCore.HCS.Oban.PaymentSweepJob do
  use Oban.Worker, queue: :hcs, max_attempts: 3

  alias VmuCore.HCS.{Company, EmployeeCard, PaymentSweep, PaymentSweepLine}
  alias VmuCore.CMS.{Account, InternalGlPoster}
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()

    central_companies =
      from(c in Company,
        where: c.liability_model == "CENTRAL" and c.status == "ACTIVE"
      )
      |> Repo.all()

    Enum.each(central_companies, &sweep_company(&1, today))
    :ok
  end

  defp sweep_company(company, sweep_date) do
    employee_cards =
      from(ec in EmployeeCard,
        join: a in Account, on: a.id == ec.employee_account_id,
        where: ec.company_id == ^company.id and ec.status == "ACTIVE" and a.current_balance > 0,
        select: %{card: ec, balance: a.current_balance}
      )
      |> Repo.all()

    return if Enum.empty?(employee_cards)

    total = Enum.reduce(employee_cards, Decimal.new(0), fn %{balance: b}, acc ->
      Decimal.add(acc, b)
    end)

    Repo.transaction(fn ->
      sweep =
        %PaymentSweep{}
        |> PaymentSweep.changeset(%{
          company_id: company.id,
          sweep_date: sweep_date,
          total_swept: total,
          employee_card_count: length(employee_cards),
          status: "PENDING"
        })
        |> Repo.insert!()

      Enum.each(employee_cards, fn %{card: ec, balance: balance} ->
        # Zero out employee balance (DR the account, effectively collecting payment)
        Repo.update_all(
          from(a in Account, where: a.id == ^ec.employee_account_id),
          set: [current_balance: Decimal.new(0)]
        )

        %PaymentSweepLine{}
        |> PaymentSweepLine.changeset(%{
          sweep_id: sweep.id,
          employee_card_id: ec.id,
          swept_amount: balance,
          status: "COMPLETED"
        })
        |> Repo.insert!()
      end)

      # Credit the parent account
      Repo.update_all(
        from(a in Account, where: a.id == ^company.parent_account_id),
        inc: [current_balance: total]
      )

      # GL: DR employee receivable pool / CR parent account
      {:ok, gl_entry} = InternalGlPoster.post(%{
        debit_account:  "hcs_employee_pool",
        credit_account: "hcs_parent_payment",
        amount:         total,
        description:    "HCS central sweep company #{company.company_code} #{sweep_date}",
        entry_id:       "hcs_sweep_#{sweep.id}"
      })

      Repo.update_all(
        from(s in PaymentSweep, where: s.id == ^sweep.id),
        set: [status: "COMPLETED", gl_entry_id: gl_entry.id]
      )
    end)
  end
end
```

### 4.4 `VmuCore.HCS.CompanyOnboarding`

```elixir
defmodule VmuCore.HCS.CompanyOnboarding do
  alias VmuCore.HCS.{Company, EmployeeCard}
  alias VmuCore.CMS.Account
  alias VmuCore.Repo

  @doc """
  Creates a corporate parent account and an HCS Company record.
  """
  def onboard_company(attrs) do
    Repo.transaction(fn ->
      # Create the parent CMS account
      {:ok, parent_account} =
        %Account{}
        |> Account.changeset(Map.merge(attrs.account_attrs, %{account_type: "CORPORATE_PARENT"}))
        |> Repo.insert()

      # Create the HCS company record
      {:ok, company} =
        %Company{}
        |> Company.changeset(Map.merge(attrs.company_attrs, %{parent_account_id: parent_account.id}))
        |> Repo.insert()

      %{company: company, parent_account: parent_account}
    end)
  end

  @doc """
  Adds an employee card under an existing HCS company.
  Creates a CMS account of type EMPLOYEE_CARD linked to the company.
  Validates that individual_limit <= company.credit_limit - sum(existing cards' limits).
  """
  def add_employee_card(company_id, employee_attrs, card_attrs) do
    company = Repo.get!(Company, company_id)

    existing_allocated =
      from(ec in EmployeeCard,
        where: ec.company_id == ^company_id and ec.status == "ACTIVE",
        select: sum(ec.individual_limit)
      )
      |> Repo.one()
      |> Kernel.||(Decimal.new(0))

    proposed_limit = Decimal.new(card_attrs.individual_limit)
    remaining_pool = Decimal.sub(company.credit_limit, existing_allocated)

    if Decimal.gt?(proposed_limit, remaining_pool) do
      {:error, :individual_limit_exceeds_company_pool}
    else
      Repo.transaction(fn ->
        {:ok, employee_account} =
          %Account{}
          |> Account.changeset(Map.merge(employee_attrs, %{account_type: "EMPLOYEE_CARD",
                                                            credit_limit: proposed_limit}))
          |> Repo.insert()

        %EmployeeCard{}
        |> EmployeeCard.changeset(Map.merge(card_attrs, %{
          company_id: company_id,
          employee_account_id: employee_account.id,
          available_individual: proposed_limit,
          status: "ACTIVE"
        }))
        |> Repo.insert()
      end)
    end
  end
end
```

---

## 5. AccountStateCoordinator Integration

HCS limit checks must be wired into the FAS authorization hot path. In `AccountStateCoordinator.do_authorize/4`, after the existing OTB check, add:

```elixir
# In AccountStateCoordinator.do_authorize/4, after open_to_buy check:
with :ok <- check_account_status(state),
     :ok <- check_open_to_buy(state, amount),
     :ok <- VmuCore.HCS.LimitController.check_hcs_limits(state.account_id, amount, channel, mcc),
     :ok <- check_velocity(state, amount, channel) do
  debit_if_authorized(state, amount)
end
```

After successful authorization, also call `LimitController.debit_limits/2`. On payment posting via `RepaymentDistributor`, call `LimitController.credit_limits/2`.

---

## 6. Oban Jobs Summary

| Job | Queue | Cron | Purpose |
|-----|-------|------|---------|
| `PaymentSweepJob` | `hcs` | `0 22 * * *` | Central liability sweep (nightly before EOD) |
| `ConsolidatedStatementJob` | `hcs` | `30 23 * * *` | Generate consolidated statements on billing day |

---

## 7. Migration

```elixir
# priv/repo/migrations/20260615000001_create_hcs_tables.exs
defmodule VmuCore.Repo.Migrations.CreateHcsTables do
  use Ecto.Migration

  def change do
    create table(:hcs_companies) do
      add :company_code,        :string, size: 20, null: false
      add :company_name,        :string, size: 200, null: false
      add :registration_no,     :string, size: 50, null: false
      add :tax_id,              :string, size: 50
      add :industry_code,       :string, size: 10
      add :liability_model,     :string, size: 20, null: false   # CENTRAL | INDIVIDUAL
      add :billing_cycle_day,   :integer, null: false, default: 25
      add :credit_limit,        :decimal, precision: 18, scale: 2, null: false
      add :available_limit,     :decimal, precision: 18, scale: 2, null: false
      add :max_employee_cards,  :integer, null: false, default: 50
      add :parent_account_id,   references(:cms_accounts, on_delete: :restrict)
      add :relationship_manager, :string, size: 100
      add :status,              :string, size: 20, null: false, default: "ACTIVE"
      add :kyc_status,          :string, size: 20, null: false, default: "PENDING"
      add :kyc_verified_at,     :utc_datetime
      timestamps(type: :utc_datetime)
    end
    create unique_index(:hcs_companies, [:company_code])
    create index(:hcs_companies, [:status])
    create index(:hcs_companies, [:parent_account_id])

    create table(:hcs_employee_cards) do
      add :company_id,           references(:hcs_companies, on_delete: :restrict), null: false
      add :employee_account_id,  references(:cms_accounts, on_delete: :restrict), null: false
      add :employee_name,        :string, size: 200, null: false
      add :employee_id,          :string, size: 50
      add :department,           :string, size: 100
      add :cost_centre,          :string, size: 50
      add :individual_limit,     :decimal, precision: 18, scale: 2, null: false
      add :available_individual, :decimal, precision: 18, scale: 2, null: false
      add :card_type,            :string, size: 20, null: false, default: "STANDARD"
      add :can_withdraw_cash,    :boolean, null: false, default: false
      add :monthly_spend_cap,    :decimal, precision: 18, scale: 2
      add :status,               :string, size: 20, null: false, default: "ACTIVE"
      add :issued_at,            :utc_datetime
      timestamps(type: :utc_datetime)
    end
    create unique_index(:hcs_employee_cards, [:company_id, :employee_account_id])
    create index(:hcs_employee_cards, [:company_id, :status])
    create index(:hcs_employee_cards, [:employee_account_id])

    create table(:hcs_spending_controls) do
      add :scope,            :string, size: 15, null: false     # COMPANY | EMPLOYEE
      add :company_id,       references(:hcs_companies, on_delete: :restrict), null: false
      add :employee_card_id, references(:hcs_employee_cards, on_delete: :restrict)
      add :control_type,     :string, size: 30, null: false
      add :mcc_codes,        {:array, :string}, default: []
      add :channels,         {:array, :string}, default: []
      add :daily_cap,        :decimal, precision: 18, scale: 2
      add :per_txn_cap,      :decimal, precision: 18, scale: 2
      add :effective_from,   :date, null: false
      add :effective_to,     :date
      add :status,           :string, size: 20, null: false, default: "ACTIVE"
      add :inserted_at,      :utc_datetime, null: false
    end
    create index(:hcs_spending_controls, [:company_id, :scope, :status])

    create table(:hcs_consolidated_statements) do
      add :company_id,       references(:hcs_companies, on_delete: :restrict), null: false
      add :statement_date,   :date, null: false
      add :period_from,      :date, null: false
      add :period_to,        :date, null: false
      add :total_spend,      :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :total_payments,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :total_fees,       :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :total_interest,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :closing_balance,  :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :minimum_payment,  :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :payment_due_date, :date, null: false
      add :employee_count,   :integer, null: false, default: 0
      add :file_path,        :string, size: 500
      add :status,           :string, size: 20, null: false, default: "GENERATED"
      add :inserted_at,      :utc_datetime, null: false
    end
    create unique_index(:hcs_consolidated_statements, [:company_id, :statement_date])

    create table(:hcs_payment_sweeps) do
      add :company_id,           references(:hcs_companies, on_delete: :restrict), null: false
      add :sweep_date,           :date, null: false
      add :total_swept,          :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :employee_card_count,  :integer, null: false, default: 0
      add :status,               :string, size: 20, null: false, default: "PENDING"
      add :gl_entry_id,          :bigint
      add :inserted_at,          :utc_datetime, null: false
    end
    create index(:hcs_payment_sweeps, [:company_id, :sweep_date])

    create table(:hcs_payment_sweep_lines) do
      add :sweep_id,         references(:hcs_payment_sweeps, on_delete: :restrict), null: false
      add :employee_card_id, references(:hcs_employee_cards, on_delete: :restrict), null: false
      add :swept_amount,     :decimal, precision: 18, scale: 2, null: false
      add :status,           :string, size: 20, null: false, default: "PENDING"
      add :inserted_at,      :utc_datetime, null: false
    end
    create index(:hcs_payment_sweep_lines, [:sweep_id])
  end
end
```

---

## 8. GL Account Codes (HCS-specific)

| Code | Name | Usage |
|------|------|-------|
| `hcs_employee_pool` | Employee Receivable Pool | Debit on central sweep collection |
| `hcs_parent_payment` | Parent Account Credit | Credit on central sweep to parent |
| `hcs_corporate_recv` | Corporate Receivable | DR when corporate charge posted |
| `hcs_corporate_liability` | Corporate Liability | CR on central liability settlement |

---

## 9. Implementation Order

1. **Migration** — 6 HCS tables  
2. **Schema modules** — `Company`, `EmployeeCard`, `SpendingControl`, `ConsolidatedStatement`, `PaymentSweep`, `PaymentSweepLine`  
3. **CompanyOnboarding** — `onboard_company/1`, `add_employee_card/3`  
4. **LimitController** — `check_hcs_limits/4`, `debit_limits/2`, `credit_limits/2`  
5. **Wire into AccountStateCoordinator** — add HCS check after OTB check  
6. **Wire into RepaymentDistributor** — call `credit_limits/2` on payment  
7. **ConsolidatedStatementGenerator** — `generate_for_date/1`  
8. **PaymentSweepJob** (Oban) — central liability nightly sweep  
9. **ConsolidatedStatementJob** (Oban) — billing cycle statement generation  
10. **Integration tests** — onboarding, limit enforcement cascade, MCC block, sweep, consolidated statement

---

## 10. Key Business Rules

- Employee `individual_limit` + all sibling individual limits must never exceed `company.credit_limit`
- `available_individual` and `company.available_limit` are decremented atomically (Repo.transaction) on authorization
- For **Individual Liability**: employee pays their own statement; company is guarantor only; no sweep
- For **Central Liability**: sweep job zeroes employee balances nightly; company parent account holds the consolidated debt
- MCC_ALLOW control type is a whitelist — only listed MCCs are allowed; any other MCC is rejected
- MCC_BLOCK is a blacklist — listed MCCs are blocked; all others are allowed
- Company-level controls apply to ALL employee cards; card-level controls are additive (both must pass)
