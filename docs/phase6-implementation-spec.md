# Phase 6 — LMS Loyalty Management System
## Implementation Specification

**Repository:** `vmu_core`  
**Module namespace:** `VmuCore.LMS`  
**Source:** VisionPlus LMS architecture (learnpaymentcard.wordpress.com)  
**Status:** PLANNED — not yet implemented  
**Prerequisite:** ITS module rename (`VmuCore.ITS` → `VmuCore.IVR`) must be done first

---

## 1. Overview

LMS (Loyalty Management System) — also called the Rewards System — allows card issuers to reward cardholders with points or cash-back rebates based on card usage. It is a full VisionPlus subsystem with:

- **Online layer** — parameter setup, account enrollment, points inquiry, manual adjustments
- **Batch layer** — points calculation, expired points processing, auto-disbursement
- **Interface layer** — receives monetary transactions from CMS, sends GL entries and settlement files to external systems, provides a real-time interface for third-party redemption systems

---

## 2. Parameter Hierarchy

```
Scheme
  └── Group (Default: "AAAA..." / Bonus: merchant-linked)
        └── Plan (Base / Supplementary / Override)
              └── Rate Table
                    └── Rate Tiers (amount thresholds → points multiplier)
```

- An account can be enrolled in **multiple Schemes**
- Every Scheme has exactly one **Default Group** (basic earned points; organisation-specific)
- A Scheme can have multiple **Bonus Groups** (merchant-linked; store can belong to multiple groups)
- Each Group has three Plan types:
  - **Base** — standard points for all transactions
  - **Supplementary** — extra points for a promotion period (added on top of Base)
  - **Override** — replaces Base + Supplementary entirely (e.g., double-points month)

---

## 3. Database Schema

### 3.1 `lms_schemes`

```sql
CREATE TABLE lms_schemes (
  id            BIGSERIAL PRIMARY KEY,
  scheme_code   VARCHAR(5)     NOT NULL UNIQUE,   -- 5 alphanumeric
  scheme_name   VARCHAR(100)   NOT NULL,
  org_id        BIGINT         NOT NULL,           -- FK → parameter org
  currency      CHAR(3)        NOT NULL DEFAULT 'AED',
  points_expiry_months  INTEGER,                  -- NULL = no expiry
  warehouse_days        INTEGER NOT NULL DEFAULT 0,  -- days before points eligible to redeem
  cycle_to_date_include BOOLEAN NOT NULL DEFAULT TRUE,
  status        VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  inserted_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at    TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
```

### 3.2 `lms_groups`

```sql
CREATE TABLE lms_groups (
  id            BIGSERIAL PRIMARY KEY,
  scheme_id     BIGINT         NOT NULL REFERENCES lms_schemes(id),
  group_code    VARCHAR(20)    NOT NULL,           -- 'AAAA' = default
  group_type    VARCHAR(10)    NOT NULL,           -- 'DEFAULT' | 'BONUS'
  group_name    VARCHAR(100)   NOT NULL,
  settlement_account VARCHAR(30),                 -- merchant settlement GL account
  status        VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  inserted_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE(scheme_id, group_code)
);
```

### 3.3 `lms_plans`

```sql
CREATE TABLE lms_plans (
  id            BIGSERIAL PRIMARY KEY,
  group_id      BIGINT         NOT NULL REFERENCES lms_groups(id),
  plan_type     VARCHAR(15)    NOT NULL,           -- 'BASE' | 'SUPPLEMENTARY' | 'OVERRIDE'
  effective_from DATE          NOT NULL,
  effective_to   DATE,                             -- NULL = open-ended
  status        VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  inserted_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
```

### 3.4 `lms_rate_tiers`

```sql
CREATE TABLE lms_rate_tiers (
  id            BIGSERIAL PRIMARY KEY,
  plan_id       BIGINT         NOT NULL REFERENCES lms_plans(id),
  tier_order    INTEGER        NOT NULL,           -- 1 = lowest threshold
  min_amount    NUMERIC(18,2)  NOT NULL,           -- minimum transaction amount for this tier
  max_amount    NUMERIC(18,2),                     -- NULL = no upper bound
  points_per_unit NUMERIC(10,4) NOT NULL,          -- points earned per 1 unit of currency
  min_qualifying_amount NUMERIC(18,2) NOT NULL DEFAULT 0.01,
  inserted_at   TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE(plan_id, tier_order)
);
```

### 3.5 `lms_accounts`

```sql
CREATE TABLE lms_accounts (
  id              BIGSERIAL PRIMARY KEY,
  lms_account_no  VARCHAR(30)    NOT NULL UNIQUE,  -- auto-generated or manual
  ar_account_id   BIGINT         NOT NULL REFERENCES cms_accounts(id),
  scheme_id       BIGINT         NOT NULL REFERENCES lms_schemes(id),
  enrollment_date DATE           NOT NULL,
  enrollment_method VARCHAR(10)  NOT NULL,          -- 'AUTO' | 'MANUAL'
  points_balance  NUMERIC(18,2)  NOT NULL DEFAULT 0,
  open_to_redeem  NUMERIC(18,2)  NOT NULL DEFAULT 0,
  lifetime_earned NUMERIC(18,2)  NOT NULL DEFAULT 0,
  lifetime_redeemed NUMERIC(18,2) NOT NULL DEFAULT 0,
  status          VARCHAR(20)    NOT NULL DEFAULT 'ACTIVE',
  inserted_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at      TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  UNIQUE(ar_account_id, scheme_id)
);
```

### 3.6 `lms_points_ledger`

```sql
CREATE TABLE lms_points_ledger (
  id              BIGSERIAL PRIMARY KEY,
  lms_account_id  BIGINT         NOT NULL REFERENCES lms_accounts(id),
  transaction_type VARCHAR(20)   NOT NULL,
    -- 'BASIC_EARNED' | 'BONUS_EARNED' | 'REDEEMED' | 'ADJUSTMENT' | 'EXPIRED'
  points_amount   NUMERIC(18,2)  NOT NULL,          -- positive = credit, negative = debit
  monetary_equiv  NUMERIC(18,2)  NOT NULL,           -- points × rate_pct / 100
  transaction_date DATE          NOT NULL,
  posting_date     DATE          NOT NULL,
  expiry_date      DATE,                             -- set at earning time
  warehouse_state  VARCHAR(10)   NOT NULL DEFAULT 'ACTIVE',
    -- 'WAREHOUSE' | 'ACTIVE' | 'HISTORY'
  plan_id          BIGINT        REFERENCES lms_plans(id),
  group_id         BIGINT        REFERENCES lms_groups(id),
  scheme_id        BIGINT        NOT NULL REFERENCES lms_schemes(id),
  merchant_id      BIGINT        REFERENCES mbs_merchants(id),
  source_clearing_id BIGINT,                        -- FK to trams_clearing_records
  idempotency_key  VARCHAR(64)   UNIQUE,
  batch_date       DATE,
  settled_at       TIMESTAMPTZ,
  statemented_at   TIMESTAMPTZ,
  inserted_at      TIMESTAMPTZ   NOT NULL DEFAULT NOW()
);

CREATE INDEX lms_points_ledger_account_date ON lms_points_ledger(lms_account_id, transaction_date);
CREATE INDEX lms_points_ledger_warehouse ON lms_points_ledger(warehouse_state, posting_date)
  WHERE warehouse_state = 'WAREHOUSE';
CREATE INDEX lms_points_ledger_expiry ON lms_points_ledger(expiry_date)
  WHERE expiry_date IS NOT NULL AND warehouse_state = 'ACTIVE';
```

### 3.7 `lms_redemptions`

```sql
CREATE TABLE lms_redemptions (
  id              BIGSERIAL PRIMARY KEY,
  lms_account_id  BIGINT         NOT NULL REFERENCES lms_accounts(id),
  redemption_type VARCHAR(20)    NOT NULL,          -- 'ONLINE' | 'THIRD_PARTY' | 'AUTO_DISBURSEMENT'
  points_redeemed NUMERIC(18,2)  NOT NULL,
  monetary_value  NUMERIC(18,2)  NOT NULL,
  disbursement_method VARCHAR(15),                  -- 'CHEQUE' | 'CREDIT' | 'VOUCHER'
  disbursement_date   DATE,
  third_party_ref     VARCHAR(50),
  status          VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
    -- 'PENDING' | 'PROCESSED' | 'SETTLED' | 'REVERSED'
  idempotency_key VARCHAR(64)    UNIQUE,
  inserted_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
```

### 3.8 `lms_merchant_settlement`

```sql
CREATE TABLE lms_merchant_settlement (
  id              BIGSERIAL PRIMARY KEY,
  merchant_id     BIGINT         NOT NULL REFERENCES mbs_merchants(id),
  group_id        BIGINT         NOT NULL REFERENCES lms_groups(id),
  settlement_period_from DATE    NOT NULL,
  settlement_period_to   DATE    NOT NULL,
  total_bonus_points NUMERIC(18,2) NOT NULL,
  charge_rate_pct    NUMERIC(6,4)  NOT NULL,        -- % charged to merchant for bonus points
  settlement_amount  NUMERIC(18,2) NOT NULL,
  settlement_method  VARCHAR(15)   NOT NULL,         -- 'DIRECT_DEBIT' | 'INVOICE' | 'BOTH'
  status          VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
  gl_entry_id     BIGINT,                            -- FK → cms_ledger_entries
  inserted_at     TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);
```

---

## 4. Elixir Modules

### 4.1 `VmuCore.LMS.Scheme` (schema)

```elixir
defmodule VmuCore.LMS.Scheme do
  use Ecto.Schema
  import Ecto.Changeset

  schema "lms_schemes" do
    field :scheme_code,          :string
    field :scheme_name,          :string
    field :org_id,               :integer
    field :currency,             :string, default: "AED"
    field :points_expiry_months, :integer
    field :warehouse_days,       :integer, default: 0
    field :cycle_to_date_include, :boolean, default: true
    field :status,               :string, default: "ACTIVE"
    has_many :groups, VmuCore.LMS.Group
    timestamps(type: :utc_datetime)
  end

  @required [:scheme_code, :scheme_name, :org_id]
  def changeset(scheme, attrs) do
    scheme
    |> cast(attrs, @required ++ [:points_expiry_months, :warehouse_days, :cycle_to_date_include, :status])
    |> validate_required(@required)
    |> validate_length(:scheme_code, max: 5)
    |> unique_constraint(:scheme_code)
  end
end
```

### 4.2 `VmuCore.LMS.RateEngine`

Calculates points earned for a monetary transaction given a plan and tier table.

```elixir
defmodule VmuCore.LMS.RateEngine do
  alias VmuCore.LMS.{Plan, RateTier}
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Returns {:ok, points} for the given lms_plan_id and transaction amount.
  Returns {:error, :below_minimum} if amount < minimum qualifying amount.
  """
  def calculate_points(plan_id, amount) do
    tiers =
      from(t in RateTier,
        where: t.plan_id == ^plan_id and t.min_amount <= ^amount,
        order_by: [desc: t.tier_order],
        limit: 1
      )
      |> Repo.one()

    case tiers do
      nil ->
        {:error, :no_applicable_tier}

      tier ->
        if D.lt?(amount, tier.min_qualifying_amount) do
          {:error, :below_minimum}
        else
          points = D.mult(amount, tier.points_per_unit)
          {:ok, D.round(points, 2, :floor)}
        end
    end
  end

  @doc """
  Resolves which plan type applies for a given transaction date:
  1. OVERRIDE if effective for date → use override, skip base and supplementary
  2. BASE + SUPPLEMENTARY if both effective
  3. BASE only
  """
  def resolve_active_plans(group_id, transaction_date) do
    plans =
      from(p in Plan,
        where:
          p.group_id == ^group_id and
          p.status == "ACTIVE" and
          p.effective_from <= ^transaction_date and
          (is_nil(p.effective_to) or p.effective_to >= ^transaction_date),
        order_by: p.plan_type
      )
      |> Repo.all()

    override = Enum.find(plans, &(&1.plan_type == "OVERRIDE"))

    if override do
      [override]
    else
      Enum.filter(plans, &(&1.plan_type in ["BASE", "SUPPLEMENTARY"]))
    end
  end
end
```

### 4.3 `VmuCore.LMS.PointsEngine`

Core points calculation engine — called from the CMS→LMS interface batch job.

```elixir
defmodule VmuCore.LMS.PointsEngine do
  alias VmuCore.LMS.{Account, Group, PointsLedger, RateEngine}
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Processes a single clearing transaction for all enrolled schemes of an AR account.
  Called from LMS.Oban.PointsCalculationJob for each transaction in the CMS→LMS file.
  """
  def process_transaction(ar_account_id, txn) do
    %{amount: amount, transaction_date: txn_date, merchant_id: merchant_id,
      clearing_record_id: clearing_id, currency: _currency} = txn

    enrollments =
      from(a in Account,
        where: a.ar_account_id == ^ar_account_id and a.status == "ACTIVE",
        preload: [scheme: [groups: :plans]]
      )
      |> Repo.all()

    Enum.each(enrollments, fn lms_account ->
      process_for_enrollment(lms_account, amount, txn_date, merchant_id, clearing_id)
    end)
  end

  defp process_for_enrollment(lms_account, amount, txn_date, merchant_id, clearing_id) do
    scheme = lms_account.scheme

    # Default group always applies
    default_group = Enum.find(scheme.groups, &(&1.group_type == "DEFAULT"))

    # Bonus groups: only if merchant is linked to the group
    bonus_groups = find_bonus_groups(scheme.groups, merchant_id)

    groups_to_process = [default_group | bonus_groups] |> Enum.reject(&is_nil/1)

    Enum.each(groups_to_process, fn group ->
      plans = RateEngine.resolve_active_plans(group.id, txn_date)

      Enum.each(plans, fn plan ->
        case RateEngine.calculate_points(plan.id, amount) do
          {:ok, points} ->
            post_earned_points(lms_account, group, plan, points, amount, txn_date, clearing_id)

          {:error, _} ->
            :ok
        end
      end)
    end)
  end

  defp post_earned_points(lms_account, group, plan, points, amount, txn_date, clearing_id) do
    txn_type = if group.group_type == "DEFAULT", do: "BASIC_EARNED", else: "BONUS_EARNED"
    warehouse_days = lms_account.scheme.warehouse_days

    expiry_date =
      case lms_account.scheme.points_expiry_months do
        nil -> nil
        months -> Date.add(txn_date, months * 30)
      end

    warehouse_state =
      if warehouse_days > 0, do: "WAREHOUSE", else: "ACTIVE"

    idempotency_key = :crypto.hash(:sha256, "lms_earn_#{clearing_id}_#{plan.id}")
                      |> Base.encode16(case: :lower)

    %PointsLedger{}
    |> PointsLedger.changeset(%{
      lms_account_id:   lms_account.id,
      transaction_type: txn_type,
      points_amount:    points,
      monetary_equiv:   amount,
      transaction_date: txn_date,
      posting_date:     Date.utc_today(),
      expiry_date:      expiry_date,
      warehouse_state:  warehouse_state,
      plan_id:          plan.id,
      group_id:         group.id,
      scheme_id:        lms_account.scheme_id,
      source_clearing_id: clearing_id,
      idempotency_key:  idempotency_key
    })
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, ledger_entry} ->
        update_account_balance(lms_account, points)
        post_provisioning_gl(lms_account, group, ledger_entry)
      {:error, _} ->
        :ok  # duplicate; already processed
    end
  end

  defp update_account_balance(lms_account, points) do
    Repo.update_all(
      from(a in Account, where: a.id == ^lms_account.id),
      inc: [points_balance: points, lifetime_earned: points]
    )
  end

  defp find_bonus_groups(groups, nil), do: []
  defp find_bonus_groups(groups, merchant_id) do
    # Query lms_group_merchants join table to find groups linked to this merchant
    from(g in Group,
      join: gm in "lms_group_merchants",
        on: gm.group_id == g.id and gm.merchant_id == ^merchant_id,
      where: g.id in ^Enum.map(groups, & &1.id) and g.group_type == "BONUS"
    )
    |> Repo.all()
  end

  defp post_provisioning_gl(lms_account, group, ledger_entry) do
    # Provisioning GL: scheme owner puts money aside to cover points cost
    # Debit: provisioning expense account, Credit: provisioning liability account
    # (GL account codes configured per-scheme in ParameterEngine)
    VmuCore.LMS.GlProvisioner.post_provisioning(lms_account.scheme_id, ledger_entry)
  end
end
```

### 4.4 `VmuCore.LMS.GlProvisioner`

```elixir
defmodule VmuCore.LMS.GlProvisioner do
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Shared.ParameterEngine
  import Decimal, as: D

  @doc """
  Posts provisioning GL for points earned.
  monetary_equiv = points × rate_pct; tax = monetary_equiv × tax_rate.
  """
  def post_provisioning(scheme_id, %{monetary_equiv: amount, id: ledger_id}) do
    rate_pct  = ParameterEngine.get("lms_provision_rate_pct_#{scheme_id}", default: "0.01")
                |> D.new()
    tax_rate  = ParameterEngine.get("lms_tax_rate_#{scheme_id}", default: "0.05")
                |> D.new()
    debit_gl  = ParameterEngine.get("lms_provision_debit_gl_#{scheme_id}", default: "7001")
    credit_gl = ParameterEngine.get("lms_provision_credit_gl_#{scheme_id}", default: "7002")

    provision_amount = D.mult(D.new(amount), rate_pct)
    tax_amount = D.mult(provision_amount, tax_rate)
    total = D.add(provision_amount, tax_amount)

    InternalGlPoster.post(%{
      debit_account:  debit_gl,
      credit_account: credit_gl,
      amount:         total,
      description:    "LMS provisioning for ledger entry #{ledger_id}",
      entry_id:       "lms_prov_#{ledger_id}"
    })
  end

  @doc """
  Posts merchant settlement GL (charge merchant for bonus points).
  """
  def post_merchant_settlement(settlement) do
    debit_gl  = "lms_merchant_receivable"
    credit_gl = "lms_merchant_settlement_income"

    InternalGlPoster.post(%{
      debit_account:  debit_gl,
      credit_account: credit_gl,
      amount:         settlement.settlement_amount,
      description:    "LMS merchant settlement #{settlement.id}",
      entry_id:       "lms_merch_#{settlement.id}"
    })
  end
end
```

### 4.5 `VmuCore.LMS.RedemptionProcessor`

```elixir
defmodule VmuCore.LMS.RedemptionProcessor do
  alias VmuCore.LMS.{Account, PointsLedger, Redemption}
  alias VmuCore.Repo
  import Ecto.Query
  import Decimal, as: D

  @doc """
  Processes a redemption request. Deducts points oldest-first.
  Checks block codes and delinquency before approval.
  """
  def redeem(lms_account_id, points_requested, opts \\ []) do
    redemption_type = Keyword.get(opts, :type, "ONLINE")
    disbursement_method = Keyword.get(opts, :method, "CREDIT")

    Repo.transaction(fn ->
      account = Repo.get!(Account, lms_account_id, lock: "FOR UPDATE")

      with :ok <- check_eligibility(account),
           :ok <- check_open_to_redeem(account, points_requested) do
        deduct_points_oldest_first(account, points_requested)
        |> create_redemption_record(account, points_requested, redemption_type, disbursement_method)
      end
    end)
  end

  defp check_eligibility(account) do
    if account.status in ["BLOCKED", "DELINQUENT"] do
      {:error, :account_ineligible}
    else
      :ok
    end
  end

  defp check_open_to_redeem(account, requested) do
    if D.lt?(account.open_to_redeem, D.new(requested)) do
      {:error, :insufficient_open_to_redeem}
    else
      :ok
    end
  end

  defp deduct_points_oldest_first(account, total_to_deduct) do
    # Fetch ACTIVE points oldest-first
    active_entries =
      from(l in PointsLedger,
        where: l.lms_account_id == ^account.id
          and l.warehouse_state == "ACTIVE"
          and l.points_amount > 0,
        order_by: [asc: l.transaction_date, asc: l.id],
        lock: "FOR UPDATE"
      )
      |> Repo.all()

    deduct_from_entries(active_entries, D.new(total_to_deduct), [])
  end

  defp deduct_from_entries([], _remaining, consumed), do: consumed
  defp deduct_from_entries(_entries, remaining, consumed) when D.lte?(remaining, 0),
    do: consumed
  defp deduct_from_entries([entry | rest], remaining, consumed) do
    deductible = D.min(entry.points_amount, remaining)
    new_balance = D.sub(entry.points_amount, deductible)

    Repo.update_all(
      from(l in PointsLedger, where: l.id == ^entry.id),
      set: [points_amount: new_balance,
            warehouse_state: if(D.eq?(new_balance, 0), do: "HISTORY", else: "ACTIVE")]
    )

    deduct_from_entries(rest, D.sub(remaining, deductible), [entry | consumed])
  end

  defp create_redemption_record(consumed_entries, account, points_requested, type, method) do
    monetary_value = calculate_monetary_value(account.scheme_id, points_requested)

    %Redemption{}
    |> Redemption.changeset(%{
      lms_account_id:     account.id,
      redemption_type:    type,
      points_redeemed:    points_requested,
      monetary_value:     monetary_value,
      disbursement_method: method,
      status:             "PENDING",
      idempotency_key:    "redeem_#{account.id}_#{System.unique_integer([:positive])}"
    })
    |> Repo.insert!()
  end

  defp calculate_monetary_value(scheme_id, points) do
    rate_pct = VmuCore.Shared.ParameterEngine.get("lms_redemption_rate_pct_#{scheme_id}",
                 default: "0.01") |> Decimal.new()
    Decimal.mult(Decimal.new(points), rate_pct)
  end
end
```

### 4.6 `VmuCore.LMS.MerchantSettlement`

```elixir
defmodule VmuCore.LMS.MerchantSettlement do
  alias VmuCore.LMS.{Group, PointsLedger, MerchantSettlement}
  alias VmuCore.LMS.GlProvisioner
  alias VmuCore.Repo
  import Ecto.Query

  @doc """
  Calculates and records merchant settlement for all bonus groups
  in the given settlement period. Called from the EOD settlement job.
  """
  def run_settlement(period_from, period_to) do
    bonus_groups =
      from(g in Group, where: g.group_type == "BONUS" and g.status == "ACTIVE")
      |> Repo.all()

    Enum.each(bonus_groups, fn group ->
      settle_group(group, period_from, period_to)
    end)
  end

  defp settle_group(group, period_from, period_to) do
    # Sum all bonus points earned in this group during the period
    total_bonus_points =
      from(l in PointsLedger,
        where: l.group_id == ^group.id
          and l.transaction_type == "BONUS_EARNED"
          and l.transaction_date >= ^period_from
          and l.transaction_date <= ^period_to
          and is_nil(l.settled_at),
        select: sum(l.points_amount)
      )
      |> Repo.one()
      |> Decimal.new()

    if Decimal.gt?(total_bonus_points, Decimal.new(0)) do
      charge_rate = VmuCore.Shared.ParameterEngine.get("lms_merchant_charge_rate_#{group.id}",
                     default: "0.005") |> Decimal.new()
      settlement_amount = Decimal.mult(total_bonus_points, charge_rate)

      settlement =
        %MerchantSettlement{}
        |> MerchantSettlement.changeset(%{
          group_id:             group.id,
          settlement_period_from: period_from,
          settlement_period_to:   period_to,
          total_bonus_points:   total_bonus_points,
          charge_rate_pct:      charge_rate,
          settlement_amount:    settlement_amount,
          settlement_method:    "DIRECT_DEBIT",
          status:               "PENDING"
        })
        |> Repo.insert!()

      {:ok, _} = GlProvisioner.post_merchant_settlement(settlement)

      # Mark ledger entries as settled
      Repo.update_all(
        from(l in PointsLedger,
          where: l.group_id == ^group.id
            and l.transaction_type == "BONUS_EARNED"
            and l.transaction_date >= ^period_from
            and l.transaction_date <= ^period_to
            and is_nil(l.settled_at)
        ),
        set: [settled_at: DateTime.utc_now()]
      )
    end
  end
end
```

---

## 5. Oban Jobs

### 5.1 `VmuCore.LMS.Oban.PointsCalculationJob`

Runs after CMS1 batch (daily). Reads the CMS→LMS monetary transaction file and posts earned points for all qualifying accounts.

```elixir
defmodule VmuCore.LMS.Oban.PointsCalculationJob do
  use Oban.Worker, queue: :lms, max_attempts: 3

  alias VmuCore.LMS.PointsEngine
  alias VmuCore.TRAMS.ClearingRecord
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_date" => batch_date_str}}) do
    batch_date = Date.from_iso8601!(batch_date_str)

    # Fetch all clearing records posted on this batch_date (already matched + posted by TRAMS)
    clearing_records =
      from(c in ClearingRecord,
        where: c.posting_date == ^batch_date and c.match_status == "MATCHED",
        select: %{
          id: c.id,
          ar_account_id: c.account_id,
          amount: c.amount,
          transaction_date: c.transaction_date,
          merchant_id: c.merchant_id,
          currency: c.currency
        }
      )
      |> Repo.all()

    Enum.each(clearing_records, fn txn ->
      PointsEngine.process_transaction(txn.ar_account_id, txn)
    end)

    :ok
  end
end
```

Cron schedule (add to `config/config.exs` Oban cron):
```elixir
%{cron: "30 23 * * *", worker: "VmuCore.LMS.Oban.PointsCalculationJob",
  args: %{batch_date: "<%= Date.to_iso8601(Date.utc_today()) %>"}}
```

### 5.2 `VmuCore.LMS.Oban.PointsExpiryJob`

Runs monthly. Moves expired ACTIVE points to EXPIRED status and reverses their balance.

```elixir
defmodule VmuCore.LMS.Oban.PointsExpiryJob do
  use Oban.Worker, queue: :lms, max_attempts: 3

  alias VmuCore.LMS.{Account, PointsLedger}
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    today = Date.utc_today()

    expired_entries =
      from(l in PointsLedger,
        where: l.warehouse_state == "ACTIVE"
          and not is_nil(l.expiry_date)
          and l.expiry_date < ^today
          and l.points_amount > 0
      )
      |> Repo.all()

    Enum.each(expired_entries, fn entry ->
      Repo.transaction(fn ->
        # Zero out the original entry
        Repo.update_all(
          from(l in PointsLedger, where: l.id == ^entry.id),
          set: [warehouse_state: "HISTORY"]
        )

        # Post a negative EXPIRED entry
        %PointsLedger{}
        |> PointsLedger.changeset(%{
          lms_account_id:  entry.lms_account_id,
          transaction_type: "EXPIRED",
          points_amount:   Decimal.negate(entry.points_amount),
          monetary_equiv:  Decimal.negate(entry.monetary_equiv),
          transaction_date: today,
          posting_date:    today,
          warehouse_state: "HISTORY",
          scheme_id:       entry.scheme_id,
          idempotency_key: "expire_#{entry.id}"
        })
        |> Repo.insert!(on_conflict: :nothing)

        # Deduct from account balance
        Repo.update_all(
          from(a in Account, where: a.id == ^entry.lms_account_id),
          inc: [points_balance: Decimal.negate(entry.points_amount)]
        )
      end)
    end)

    :ok
  end
end
```

### 5.3 `VmuCore.LMS.Oban.AutoDisbursementJob`

Runs at configurable frequency. Processes auto-disbursement when account's `open_to_redeem ≥ disbursement_packet`.

```elixir
defmodule VmuCore.LMS.Oban.AutoDisbursementJob do
  use Oban.Worker, queue: :lms, max_attempts: 3

  alias VmuCore.LMS.{Account, RedemptionProcessor}
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.Repo
  import Ecto.Query

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scheme_id" => scheme_id}}) do
    disbursement_packet =
      ParameterEngine.get("lms_disbursement_packet_#{scheme_id}", default: "500")
      |> Decimal.new()

    disbursement_method =
      ParameterEngine.get("lms_disbursement_method_#{scheme_id}", default: "CREDIT")

    eligible_accounts =
      from(a in Account,
        where: a.scheme_id == ^scheme_id
          and a.status == "ACTIVE"
          and a.open_to_redeem >= ^disbursement_packet
      )
      |> Repo.all()

    Enum.each(eligible_accounts, fn account ->
      # If disbursement_packet = 0, disburse all; otherwise disburse in packets
      amount = if Decimal.eq?(disbursement_packet, 0),
        do: account.open_to_redeem,
        else: disbursement_packet

      RedemptionProcessor.redeem(account.id, amount,
        type: "AUTO_DISBURSEMENT",
        method: disbursement_method
      )
    end)

    :ok
  end
end
```

---

## 6. CMS → LMS Interface (`VmuCore.LMS.CmsInterface`)

VisionPlus CMS generates an interface file to LMS after CMS1 batch. In vMu, this is a direct Ecto query rather than a file — but the flow is preserved.

```elixir
defmodule VmuCore.LMS.CmsInterface do
  @moduledoc """
  Interface from CMS (AR System) to LMS.
  CMS sends monetary transactions to LMS for points calculation.
  In VisionPlus mainframe this is a sequential file; in vMu it is a direct
  DB query after the EOD TRAMS matching run completes.
  """

  @doc """
  Called at end of TRAMS clearing reconciliation to trigger LMS points
  calculation for the batch_date. Enqueues a PointsCalculationJob.
  """
  def trigger_points_calculation(batch_date) do
    %{batch_date: Date.to_iso8601(batch_date)}
    |> VmuCore.LMS.Oban.PointsCalculationJob.new()
    |> Oban.insert()
  end

  @doc """
  Called from CMS AccountStateCoordinator when an account is enrolled
  (account creation, CDM approval) to auto-enroll in configured schemes.
  """
  def auto_enroll(ar_account_id, org_id) do
    # Fetch all schemes configured for auto-enrollment at this org
    schemes = VmuCore.LMS.Scheme
              |> Repo.all(where: [org_id: org_id, status: "ACTIVE"])

    Enum.each(schemes, fn scheme ->
      VmuCore.LMS.Enrollment.enroll(ar_account_id, scheme.id, method: "AUTO")
    end)
  end
end
```

---

## 7. Enrollment Module

```elixir
defmodule VmuCore.LMS.Enrollment do
  alias VmuCore.LMS.Account
  alias VmuCore.Repo

  def enroll(ar_account_id, scheme_id, opts \\ []) do
    method = Keyword.get(opts, :method, "MANUAL")
    lms_account_no = generate_lms_account_no(scheme_id)

    %Account{}
    |> Account.changeset(%{
      lms_account_no:   lms_account_no,
      ar_account_id:    ar_account_id,
      scheme_id:        scheme_id,
      enrollment_date:  Date.utc_today(),
      enrollment_method: method,
      status:           "ACTIVE"
    })
    |> Repo.insert(on_conflict: :nothing)
  end

  defp generate_lms_account_no(scheme_id) do
    # Format: LMS + scheme_id (zero-padded 4) + timestamp micros
    ts = System.system_time(:microsecond)
    "LMS#{String.pad_leading(to_string(scheme_id), 4, "0")}#{ts}"
  end
end
```

---

## 8. Migration Sequence

Create a single migration file:

```elixir
# priv/repo/migrations/20260614000001_create_lms_tables.exs
defmodule VmuCore.Repo.Migrations.CreateLmsTables do
  use Ecto.Migration

  def change do
    create table(:lms_schemes) do
      add :scheme_code,          :string, size: 5, null: false
      add :scheme_name,          :string, size: 100, null: false
      add :org_id,               :bigint, null: false
      add :currency,             :string, size: 3, null: false, default: "AED"
      add :points_expiry_months, :integer
      add :warehouse_days,       :integer, null: false, default: 0
      add :cycle_to_date_include, :boolean, null: false, default: true
      add :status,               :string, size: 20, null: false, default: "ACTIVE"
      timestamps(type: :utc_datetime)
    end
    create unique_index(:lms_schemes, [:scheme_code])

    create table(:lms_groups) do
      add :scheme_id,       references(:lms_schemes, on_delete: :restrict), null: false
      add :group_code,      :string, size: 20, null: false
      add :group_type,      :string, size: 10, null: false    # DEFAULT | BONUS
      add :group_name,      :string, size: 100, null: false
      add :settlement_account, :string, size: 30
      add :status,          :string, size: 20, null: false, default: "ACTIVE"
      add :inserted_at,     :utc_datetime, null: false
    end
    create unique_index(:lms_groups, [:scheme_id, :group_code])

    # Join table: which merchants belong to which bonus group
    create table(:lms_group_merchants) do
      add :group_id,    references(:lms_groups, on_delete: :restrict), null: false
      add :merchant_id, references(:mbs_merchants, on_delete: :restrict), null: false
      add :inserted_at, :utc_datetime, null: false
    end
    create unique_index(:lms_group_merchants, [:group_id, :merchant_id])

    create table(:lms_plans) do
      add :group_id,       references(:lms_groups, on_delete: :restrict), null: false
      add :plan_type,      :string, size: 15, null: false   # BASE | SUPPLEMENTARY | OVERRIDE
      add :effective_from, :date, null: false
      add :effective_to,   :date
      add :status,         :string, size: 20, null: false, default: "ACTIVE"
      add :inserted_at,    :utc_datetime, null: false
    end

    create table(:lms_rate_tiers) do
      add :plan_id,               references(:lms_plans, on_delete: :restrict), null: false
      add :tier_order,            :integer, null: false
      add :min_amount,            :decimal, precision: 18, scale: 2, null: false
      add :max_amount,            :decimal, precision: 18, scale: 2
      add :points_per_unit,       :decimal, precision: 10, scale: 4, null: false
      add :min_qualifying_amount, :decimal, precision: 18, scale: 2, null: false, default: "0.01"
      add :inserted_at,           :utc_datetime, null: false
    end
    create unique_index(:lms_rate_tiers, [:plan_id, :tier_order])

    create table(:lms_accounts) do
      add :lms_account_no,      :string, size: 30, null: false
      add :ar_account_id,       references(:cms_accounts, on_delete: :restrict), null: false
      add :scheme_id,           references(:lms_schemes, on_delete: :restrict), null: false
      add :enrollment_date,     :date, null: false
      add :enrollment_method,   :string, size: 10, null: false
      add :points_balance,      :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :open_to_redeem,      :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :lifetime_earned,     :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :lifetime_redeemed,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :status,              :string, size: 20, null: false, default: "ACTIVE"
      timestamps(type: :utc_datetime)
    end
    create unique_index(:lms_accounts, [:lms_account_no])
    create unique_index(:lms_accounts, [:ar_account_id, :scheme_id])
    create index(:lms_accounts, [:ar_account_id])

    create table(:lms_points_ledger) do
      add :lms_account_id,     references(:lms_accounts, on_delete: :restrict), null: false
      add :transaction_type,   :string, size: 20, null: false
      add :points_amount,      :decimal, precision: 18, scale: 2, null: false
      add :monetary_equiv,     :decimal, precision: 18, scale: 2, null: false
      add :transaction_date,   :date, null: false
      add :posting_date,       :date, null: false
      add :expiry_date,        :date
      add :warehouse_state,    :string, size: 10, null: false, default: "ACTIVE"
      add :plan_id,            references(:lms_plans, on_delete: :nilify_all)
      add :group_id,           references(:lms_groups, on_delete: :nilify_all)
      add :scheme_id,          references(:lms_schemes, on_delete: :restrict), null: false
      add :merchant_id,        references(:mbs_merchants, on_delete: :nilify_all)
      add :source_clearing_id, :bigint
      add :idempotency_key,    :string, size: 64
      add :batch_date,         :date
      add :settled_at,         :utc_datetime
      add :statemented_at,     :utc_datetime
      add :inserted_at,        :utc_datetime, null: false
    end
    create unique_index(:lms_points_ledger, [:idempotency_key])
    create index(:lms_points_ledger, [:lms_account_id, :transaction_date])
    create index(:lms_points_ledger, [:warehouse_state, :posting_date])
    create index(:lms_points_ledger, [:expiry_date])

    create table(:lms_redemptions) do
      add :lms_account_id,     references(:lms_accounts, on_delete: :restrict), null: false
      add :redemption_type,    :string, size: 20, null: false
      add :points_redeemed,    :decimal, precision: 18, scale: 2, null: false
      add :monetary_value,     :decimal, precision: 18, scale: 2, null: false
      add :disbursement_method, :string, size: 15
      add :disbursement_date,  :date
      add :third_party_ref,    :string, size: 50
      add :status,             :string, size: 20, null: false, default: "PENDING"
      add :idempotency_key,    :string, size: 64
      add :inserted_at,        :utc_datetime, null: false
    end
    create unique_index(:lms_redemptions, [:idempotency_key])
    create index(:lms_redemptions, [:lms_account_id])

    create table(:lms_merchant_settlement) do
      add :merchant_id,            references(:mbs_merchants, on_delete: :restrict), null: false
      add :group_id,               references(:lms_groups, on_delete: :restrict), null: false
      add :settlement_period_from, :date, null: false
      add :settlement_period_to,   :date, null: false
      add :total_bonus_points,     :decimal, precision: 18, scale: 2, null: false
      add :charge_rate_pct,        :decimal, precision: 6, scale: 4, null: false
      add :settlement_amount,      :decimal, precision: 18, scale: 2, null: false
      add :settlement_method,      :string, size: 15, null: false
      add :status,                 :string, size: 20, null: false, default: "PENDING"
      add :gl_entry_id,            :bigint
      add :inserted_at,            :utc_datetime, null: false
    end
    create index(:lms_merchant_settlement, [:merchant_id, :settlement_period_from])
  end
end
```

---

## 9. Application.ex Changes

Add LMS Oban queues to config:

```elixir
# In config/config.exs, add to queues:
config :vmu_core, Oban,
  queues: [
    default: 10,
    eod: 2,
    lms: 5,        # ← add this
    clearing: 4
  ]
```

No new supervised processes needed — all LMS work is Oban-driven or direct function calls.

---

## 10. Integration Points

| From | To | Trigger | Action |
|------|-----|---------|--------|
| `CMS.EOD.FlushGLJob` | `LMS.CmsInterface.trigger_points_calculation/1` | After EOD GL flush | Enqueue PointsCalculationJob for batch date |
| `CDM.ApplicationScorer` (account approved) | `LMS.CmsInterface.auto_enroll/2` | New account creation | Enroll in org-configured schemes |
| `CMS.AccountStateCoordinator` (block/delinquency) | `LMS.Account` status update | Block code applied | Set LMS account status to block redemption |
| `TRAMS.MastercardIpm` / `TRAMS.VisaBaseIi` | `LMS.Oban.PointsCalculationJob` | Clearing record matched | Points calculation processes clearing records |

---

## 11. Transaction History States

Per VisionPlus LMS spec, all points transactions pass through three states:

| State | `warehouse_state` | Meaning |
|-------|-------------------|---------|
| Warehouse | `"WAREHOUSE"` | Points received but not yet calculated/posted (waiting period) |
| Active | `"ACTIVE"` | Points calculated and posted; not yet statemented or settled |
| History | `"HISTORY"` | Posted + statemented on loyalty account + settled with merchant |

The `warehouse_days` parameter on `lms_schemes` controls how long newly earned points stay in `WAREHOUSE` before moving to `ACTIVE`. A nightly job (`PointsCalculationJob`) advances `WAREHOUSE` → `ACTIVE` when the warehouse period has passed. Points move to `HISTORY` when both `settled_at` and `statemented_at` are set.

---

## 12. Implementation Order

1. **Migration** — create all 8 tables  
2. **Schema modules** — `Scheme`, `Group`, `Plan`, `RateTier`, `Account`, `PointsLedger`, `Redemption`, `MerchantSettlement`  
3. **RateEngine** — `calculate_points/2`, `resolve_active_plans/2`  
4. **PointsEngine** — `process_transaction/2`  
5. **GlProvisioner** — `post_provisioning/2`, `post_merchant_settlement/1`  
6. **Enrollment** — `enroll/3`, `generate_lms_account_no/1`  
7. **CmsInterface** — `trigger_points_calculation/1`, `auto_enroll/2`  
8. **RedemptionProcessor** — `redeem/3`  
9. **MerchantSettlement** — `run_settlement/2`  
10. **Oban Jobs** — `PointsCalculationJob`, `PointsExpiryJob`, `AutoDisbursementJob`  
11. **Oban cron wiring** in `config.exs`  
12. **Integration hooks** — add `CmsInterface.trigger_points_calculation` call in `FlushGLJob`; add `CmsInterface.auto_enroll` call in CDM account approval flow  
13. **Integration tests** — enrollment, points earning, redemption oldest-first, expiry, merchant settlement GL
