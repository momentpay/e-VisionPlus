# Phase 2 Implementation Spec — CMS Credit Core + CTA Card Issuance

**Target:** Weeks 5–12  
**Outcome:** Credit card can be issued (physical + digital), funded, billed monthly, and interest-accrued. Physical card production pipeline operational with HSM PIN issuance.

---

## Task Overview

| # | Task | Module | Depends On |
|---|---|---|---|
| 7 | `cms_ledger_entries` + `InternalGlPoster` | vMu_cms | T3 |
| 8 | Velocity matrix extension to `block_parameters` | vMu_cms | T3 |
| 9 | `InterestEngine` — ADB + fee calculation | vMu_cms | T7, T8 |
| 10 | EOD Oban workflow (6-step sequential) | vMu_cms | T9 |
| 11 | `StatementGenerator` + `RepaymentDistributor` | vMu_cms | T10 |
| 12 | CTA `EmbossingFileGenerator` + `CardOrderManager` + bureau adapter | vMu_cta | T3 |
| 13 | CTA `StockInventoryManager` | vMu_cta | T12 |
| 14 | HSM `PinIssuanceService` | vMu_cta | T12 |
| 15 | Card activation workflow | vMu_cms + vMu_cta | T13, T14 |

---

## Task 7 — CMS Ledger Entries (Double-Entry Journal)

VisionPlus uses an internal double-entry GL for every posting. Every credit/debit to a cardholder account generates a matching journal entry. These entries feed the EOD GL extract to core banking.

### Migration: `cms_ledger_entries`
```sql
CREATE TABLE cms_ledger_entries (
    entry_id            UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          UUID        NOT NULL REFERENCES cms_accounts(account_id),
    -- Double-entry fields
    transaction_code    VARCHAR(10) NOT NULL,  -- VP transaction codes: PURCH, PYMT, INT, FEE, ADJ, RFND
    dr_account_code     VARCHAR(20) NOT NULL,  -- GL account debited (internal chart of accounts)
    cr_account_code     VARCHAR(20) NOT NULL,  -- GL account credited
    amount              DECIMAL(18,2) NOT NULL CHECK (amount > 0),
    currency            VARCHAR(3)  NOT NULL DEFAULT 'AED',
    -- Posting context
    source_type         VARCHAR(20) NOT NULL,  -- AUTH, CLEARING, EOD, MANUAL, DISPUTE, REVERSAL
    source_reference    VARCHAR(64),           -- STAN, IPM reference, or Oban job ID
    posting_date        DATE        NOT NULL,
    value_date          DATE        NOT NULL,
    -- Bucket impact
    bucket_affected     VARCHAR(20) NOT NULL,  -- RETAIL, CASH, INTEREST, FEE, DISPUTED
    -- Idempotency
    idempotency_key     VARCHAR(128) NOT NULL UNIQUE,
    -- Audit
    posted_by           VARCHAR(50) NOT NULL DEFAULT 'SYSTEM',
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);
CREATE INDEX ON cms_ledger_entries (account_id, posting_date);
CREATE INDEX ON cms_ledger_entries (source_reference);
CREATE INDEX ON cms_ledger_entries (idempotency_key);
```

### GL Account Codes (VisionPlus standard chart)
```
11000  — Cardholder Receivable (retail)
11010  — Cardholder Receivable (cash advance)
11020  — Accrued Interest Receivable
11030  — Fee Receivable
21000  — Cards Payable (clearing settlement)
41000  — Interest Income
41010  — Fee Income
41020  — Interchange Income
51000  — Funding / Loaded Amount (prepaid)
```

### Module: `lib/vmu_core/cms/internal_gl_poster.ex`
```elixir
defmodule VmuCore.CMS.InternalGlPoster do
  @moduledoc """
  Posts double-entry journal entries to cms_ledger_entries.
  Idempotency key prevents duplicate posts on retry.
  """
  import Ecto.Query
  alias VmuCore.{Repo, CMS.LedgerEntry}

  @doc """
  Post a journal entry. Idempotent — safe to call multiple times with the same key.

  Returns {:ok, entry} | {:error, :already_posted} | {:error, changeset}
  """
  def post(attrs) do
    key = Map.fetch!(attrs, :idempotency_key)

    case Repo.get_by(LedgerEntry, idempotency_key: key) do
      %LedgerEntry{} = existing ->
        {:error, :already_posted, existing}

      nil ->
        %LedgerEntry{}
        |> LedgerEntry.changeset(attrs)
        |> Repo.insert()
    end
  end

  @doc "Post a purchase (retail) to the cardholder ledger."
  def post_purchase(account_id, amount, stan, posting_date) do
    post(%{
      account_id:       account_id,
      transaction_code: "PURCH",
      dr_account_code:  "11000",
      cr_account_code:  "21000",
      amount:           amount,
      source_type:      "CLEARING",
      source_reference: stan,
      posting_date:     posting_date,
      value_date:       posting_date,
      bucket_affected:  "RETAIL",
      idempotency_key:  "PURCH:#{stan}:#{account_id}"
    })
  end

  @doc "Post accrued interest (called by InterestEngine during EOD)."
  def post_interest(account_id, amount, eod_date, job_id) do
    post(%{
      account_id:       account_id,
      transaction_code: "INT",
      dr_account_code:  "11020",
      cr_account_code:  "41000",
      amount:           amount,
      source_type:      "EOD",
      source_reference: job_id,
      posting_date:     eod_date,
      value_date:       eod_date,
      bucket_affected:  "INTEREST",
      idempotency_key:  "INT:#{account_id}:#{eod_date}"
    })
  end

  @doc "Post a fee (late fee, cash advance fee, annual fee)."
  def post_fee(account_id, fee_type, amount, eod_date, job_id) do
    post(%{
      account_id:       account_id,
      transaction_code: "FEE",
      dr_account_code:  "11030",
      cr_account_code:  "41010",
      amount:           amount,
      source_type:      "EOD",
      source_reference: job_id,
      posting_date:     eod_date,
      value_date:       eod_date,
      bucket_affected:  "FEE",
      idempotency_key:  "FEE:#{fee_type}:#{account_id}:#{eod_date}"
    })
  end

  @doc "Post a cardholder payment."
  def post_payment(account_id, amount, reference, payment_date) do
    post(%{
      account_id:       account_id,
      transaction_code: "PYMT",
      dr_account_code:  "21000",
      cr_account_code:  "11000",
      amount:           amount,
      source_type:      "CLEARING",
      source_reference: reference,
      posting_date:     payment_date,
      value_date:       payment_date,
      bucket_affected:  "RETAIL",
      idempotency_key:  "PYMT:#{reference}:#{account_id}"
    })
  end
end
```

---

## Task 8 — Velocity Matrix Extension

VisionPlus controls spending velocity across 40 parameters: 4 channels × 5 frequencies × 2 dimensions (amount + count).

### Channels: `pos`, `atm`, `contactless`, `overall`
### Frequencies: `lifetime`, `yearly`, `monthly`, `weekly`, `daily`
### Dimensions: `spend_limit` (max amount), `txn_limit` (max count)

Store velocity limits as JSONB on `cms_accounts.velocity_limits`. Defaults come from `block_parameters`.

### Extend `block_parameters` migration:
```sql
ALTER TABLE block_parameters
  ADD COLUMN velocity_matrix JSONB NOT NULL DEFAULT '{}';
```

### Velocity matrix JSON structure:
```json
{
  "pos":         { "daily": {"spend": 5000, "count": 20}, "weekly": {"spend": 15000, "count": 60}, "monthly": {"spend": 50000, "count": 200}, "yearly": {"spend": 500000, "count": 2000}, "lifetime": {"spend": null, "count": null} },
  "atm":         { "daily": {"spend": 2000, "count": 5},  "weekly": {"spend": 5000,  "count": 10}, "monthly": {"spend": 10000, "count": 30},  "yearly": {"spend": 100000, "count": 300},  "lifetime": {"spend": null, "count": null} },
  "contactless": { "daily": {"spend": 1000, "count": 10}, "weekly": {"spend": 3000,  "count": 30}, "monthly": {"spend": 10000, "count": 100}, "yearly": {"spend": 100000, "count": 1000}, "lifetime": {"spend": null, "count": null} },
  "overall":     { "daily": {"spend": 6000, "count": 25}, "weekly": {"spend": 18000, "count": 75}, "monthly": {"spend": 60000, "count": 250}, "yearly": {"spend": 600000, "count": 2500}, "lifetime": {"spend": null, "count": null} }
}
```

### Module: `lib/vmu_core/cms/velocity_checker.ex`
```elixir
defmodule VmuCore.CMS.VelocityChecker do
  @moduledoc """
  Checks transaction against the account's velocity matrix.
  Delegates actual counter state to mw_risk VelocityPipeline (reused from vMu_cdm).
  """

  alias VmuCore.Shared.ParameterEngine

  @channels ~w[pos atm contactless overall]
  @frequencies ~w[daily weekly monthly yearly lifetime]

  @doc """
  Check if a transaction is within velocity limits.
  Returns :ok | {:velocity_exceeded, channel, frequency, dimension}
  """
  def check(account_id, amount, channel, account_velocity_limits, sys_id, bank_id, logo_id, block_id) do
    # Merge account-level overrides on top of block defaults
    block_limits = resolve_block_limits(sys_id, bank_id, logo_id, block_id)
    effective_limits = Map.merge(block_limits, account_velocity_limits)

    channel_key = to_string(channel)
    channel_limits = Map.get(effective_limits, channel_key, %{})
    overall_limits = Map.get(effective_limits, "overall", %{})

    with :ok <- check_channel_limits(account_id, channel_key, amount, channel_limits),
         :ok <- check_channel_limits(account_id, "overall", amount, overall_limits) do
      :ok
    end
  end

  defp check_channel_limits(account_id, channel, amount, limits) do
    Enum.reduce_while(@frequencies, :ok, fn freq, :ok ->
      case Map.get(limits, freq) do
        nil -> {:cont, :ok}
        freq_limits ->
          case check_one(account_id, channel, freq, amount, freq_limits) do
            :ok            -> {:cont, :ok}
            {:exceeded, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp check_one(account_id, channel, frequency, amount, %{"spend" => spend_limit, "count" => count_limit}) do
    # Delegate actual window counters to MwRisk.VelocityPipeline
    current = MwRisk.VelocityPipeline.get_counters(account_id, channel, frequency)

    cond do
      spend_limit != nil and Decimal.compare(Decimal.add(current.spend, amount), Decimal.new("#{spend_limit}")) == :gt ->
        {:exceeded, {:velocity, channel, frequency, :spend}}

      count_limit != nil and current.count >= count_limit ->
        {:exceeded, {:velocity, channel, frequency, :count}}

      true -> :ok
    end
  end

  defp resolve_block_limits(sys_id, bank_id, logo_id, block_id) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :velocity_matrix) do
      {:ok, matrix} -> matrix
      {:error, _}   -> %{}
    end
  end
end
```

---

## Task 9 — InterestEngine (Average Daily Balance)

VisionPlus calculates interest using Average Daily Balance (ADB). This runs during EOD Step 2 for all accounts in the billing cycle.

### Module: `lib/vmu_core/cms/interest_engine.ex`
```elixir
defmodule VmuCore.CMS.InterestEngine do
  @moduledoc """
  Calculates interest charges using the Average Daily Balance (ADB) method.

  VisionPlus interest calculation:
    1. Sum the daily ending balance for each day in the billing cycle
    2. Divide by the number of days in the cycle → ADB
    3. Apply the periodic rate: APR / 365 * days_in_cycle
    4. Accrue: ADB × periodic_rate = interest charge

  Separate calculations for retail and cash advance balances
  (cash typically carries a higher APR with no grace period).
  """

  alias VmuCore.{Repo, CMS.LedgerEntry, Shared.ParameterEngine}
  import Ecto.Query

  @doc """
  Calculate and post interest for one account's billing cycle.
  Returns {:ok, interest_amount} | {:error, reason}
  """
  def accrue_interest(account_id, sys_id, bank_id, logo_id, block_id, cycle_start, cycle_end, eod_date, job_id) do
    with {:ok, apr}          <- ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :apr_percentage),
         {:ok, cash_apr}     <- ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :cash_apr_percentage),
         {:ok, grace_days}   <- get_grace_days(sys_id, bank_id, logo_id, block_id),
         adb_retail          <- calculate_adb(account_id, cycle_start, cycle_end, "RETAIL"),
         adb_cash            <- calculate_adb(account_id, cycle_start, cycle_end, "CASH"),
         retail_interest     <- calculate_interest(adb_retail, apr, cycle_start, cycle_end, grace_days),
         cash_interest       <- calculate_interest(adb_cash, cash_apr, cycle_start, cycle_end, 0) do

      total = Decimal.add(retail_interest, cash_interest)

      if Decimal.compare(total, Decimal.new("0")) == :gt do
        VmuCore.CMS.InternalGlPoster.post_interest(account_id, total, eod_date, job_id)
        {:ok, total}
      else
        {:ok, Decimal.new("0")}
      end
    end
  end

  # ADB = sum of daily balances / number of days
  defp calculate_adb(account_id, cycle_start, cycle_end, bucket) do
    daily_balances = get_daily_balances(account_id, cycle_start, cycle_end, bucket)
    days = Date.diff(cycle_end, cycle_start) + 1

    sum = Enum.reduce(daily_balances, Decimal.new("0"), &Decimal.add/2)
    Decimal.div(sum, Decimal.new("#{days}"))
  end

  # Reconstruct daily balance by replaying ledger entries
  defp get_daily_balances(account_id, cycle_start, cycle_end, bucket) do
    entries =
      Repo.all(
        from e in LedgerEntry,
          where: e.account_id == ^account_id
            and e.bucket_affected == ^bucket
            and e.posting_date >= ^cycle_start
            and e.posting_date <= ^cycle_end,
          order_by: e.posting_date,
          select: {e.posting_date, e.transaction_code, e.amount}
      )

    # Walk day by day, applying entries
    Date.range(cycle_start, cycle_end)
    |> Enum.scan(Decimal.new("0"), fn date, balance ->
      day_delta =
        entries
        |> Enum.filter(fn {d, _, _} -> d == date end)
        |> Enum.reduce(Decimal.new("0"), fn {_, txn_code, amount}, acc ->
          if txn_code in ["PURCH", "INT", "FEE"] do
            Decimal.add(acc, amount)
          else
            Decimal.sub(acc, amount)  # PYMT, RFND reduce balance
          end
        end)

      Decimal.add(balance, day_delta)
    end)
  end

  defp calculate_interest(adb, apr, cycle_start, cycle_end, grace_days) do
    days = Date.diff(cycle_end, cycle_start) + 1 - grace_days
    days = max(days, 0)

    # Periodic rate = APR / 365 * days
    daily_rate = Decimal.div(apr, Decimal.new("36500"))  # APR% / 365 / 100
    periodic_rate = Decimal.mult(daily_rate, Decimal.new("#{days}"))

    Decimal.mult(adb, periodic_rate)
    |> Decimal.round(2, :half_up)
  end

  defp get_grace_days(sys_id, bank_id, logo_id, block_id) do
    case ParameterEngine.get(sys_id, bank_id, logo_id, block_id, :grace_period_days) do
      {:ok, days} -> {:ok, days}
      {:error, _} -> {:ok, 0}
    end
  end
end
```

---

## Task 10 — EOD Oban Workflow (6-Step Sequential)

The EOD workflow runs nightly. It must be: sequential (no concurrent steps), idempotent (crash-safe, re-runnable), and account-level (each account processed independently so a failure on one doesn't block others).

### Oban job structure
```
EodCoordinator (triggered by cron at 23:00)
  └── spawns one EodAccountJob per account in tonight's billing cycle
        ├── Step 1: LockJob       — set account_status = :posting_in_progress
        ├── Step 2: AccrueJob     — InterestEngine.accrue_interest/9
        ├── Step 3: AgingJob      — advance delinquency bucket if minimum payment missed
        ├── Step 4: BillingJob    — StatementGenerator.generate/2
        ├── Step 5: UnlockJob     — restore account_status = :active
        └── Step 6: GlFlushJob    — extract ledger entries to GL file for core banking
```

### `lib/vmu_core/cms/eod/coordinator.ex`
```elixir
defmodule VmuCore.CMS.EOD.Coordinator do
  use Oban.Worker, queue: :eod, max_attempts: 1, unique: [period: 86_400]

  import Ecto.Query
  alias VmuCore.{Repo, CMS.Account}

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)

    # Find all accounts whose cycle_code matches today's day-of-month
    day = eod_date.day

    accounts_in_cycle =
      Repo.all(from a in Account,
        where: a.cycle_code == ^day and a.account_status == "ACTIVE",
        select: a.account_id)

    # Enqueue one account job per account — they run concurrently
    Enum.each(accounts_in_cycle, fn account_id ->
      %{"account_id" => account_id, "eod_date" => eod_date_str}
      |> VmuCore.CMS.EOD.AccountJob.new()
      |> Oban.insert!()
    end)

    :ok
  end
end
```

### `lib/vmu_core/cms/eod/account_job.ex`
```elixir
defmodule VmuCore.CMS.EOD.AccountJob do
  use Oban.Worker, queue: :eod_accounts, max_attempts: 3

  alias VmuCore.CMS.EOD.Steps

  @impl Oban.Worker
  def perform(%Oban.Job{id: job_id, args: %{"account_id" => account_id, "eod_date" => eod_date_str}}) do
    eod_date = Date.from_iso8601!(eod_date_str)
    ctx = %{account_id: account_id, eod_date: eod_date, job_id: "eod:#{job_id}"}

    # Sequential steps — each step is idempotent
    with :ok <- Steps.lock_account(ctx),
         :ok <- Steps.accrue_interest(ctx),
         :ok <- Steps.age_delinquency(ctx),
         :ok <- Steps.generate_statement(ctx),
         :ok <- Steps.unlock_account(ctx),
         :ok <- Steps.flush_gl(ctx) do
      :ok
    else
      {:error, reason} ->
        # Unlock the account before propagating the error
        Steps.unlock_account(ctx)
        {:error, reason}
    end
  end
end
```

### `lib/vmu_core/cms/eod/steps.ex`
```elixir
defmodule VmuCore.CMS.EOD.Steps do
  alias VmuCore.{Repo, CMS.Account, CMS.InterestEngine, CMS.StatementGenerator}
  import Ecto.Query

  def lock_account(%{account_id: id}) do
    case Repo.update_all(
      from(a in Account, where: a.account_id == ^id and a.account_status == "ACTIVE"),
      set: [account_status: "POSTING_IN_PROGRESS"]
    ) do
      {1, _} -> :ok
      {0, _} -> {:error, :already_locked_or_not_active}
    end
  end

  def unlock_account(%{account_id: id}) do
    Repo.update_all(
      from(a in Account, where: a.account_id == ^id and a.account_status == "POSTING_IN_PROGRESS"),
      set: [account_status: "ACTIVE"]
    )
    :ok  # Always succeeds — we never want to block unlock
  end

  def accrue_interest(%{account_id: id, eod_date: eod_date, job_id: job_id}) do
    account = Repo.get!(Account, id)
    # Cycle: previous cycle_code day to today
    cycle_start = Date.add(eod_date, -30)  # approximate; use actual cycle_code logic
    InterestEngine.accrue_interest(
      id, account.sys_id, account.bank_id, account.logo_id, account.block_id,
      cycle_start, eod_date, eod_date, job_id
    )
    :ok
  end

  def age_delinquency(%{account_id: id, eod_date: eod_date}) do
    account = Repo.get!(Account, id)
    # If minimum payment not received since last statement, advance bucket
    if payment_missed?(account, eod_date) do
      new_bucket = min(account.delinquency_bucket + 30, 120)
      Repo.update_all(
        from(a in Account, where: a.account_id == ^id),
        set: [delinquency_bucket: new_bucket]
      )
    end
    :ok
  end

  def generate_statement(ctx), do: StatementGenerator.generate(ctx)

  def flush_gl(%{account_id: id, eod_date: eod_date}) do
    VmuCore.CMS.GlExtractor.extract_for_account(id, eod_date)
  end

  defp payment_missed?(account, eod_date) do
    # Check if last_payment_date is before current cycle start
    account.last_payment_date == nil or
      Date.compare(account.last_payment_date, Date.add(eod_date, -30)) == :lt
  end
end
```

### Oban cron config (`config/config.exs`):
```elixir
config :vmu_core, Oban,
  repo: VmuCore.Repo,
  queues: [eod: 1, eod_accounts: 50, default: 10],
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"0 23 * * *", VmuCore.CMS.EOD.Coordinator, args: %{}}
     ]}
  ]
```

---

## Task 11 — StatementGenerator + RepaymentDistributor

### `lib/vmu_core/cms/statement_generator.ex`
```elixir
defmodule VmuCore.CMS.StatementGenerator do
  alias VmuCore.{Repo, CMS.Account, CMS.BalanceBucket, CMS.LedgerEntry}
  alias VmuCore.Shared.ParameterEngine
  import Ecto.Query

  @doc "Generate and persist a statement for the account."
  def generate(%{account_id: id, eod_date: eod_date, job_id: _job_id}) do
    account = Repo.get!(Account, id)
    bucket  = Repo.get_by!(BalanceBucket, account_id: id)

    total_due     = Account.total_balance(account, bucket)
    min_payment   = calculate_minimum(total_due, account, bucket)
    next_due_date = Date.add(eod_date, 25)  # 25 days after statement date

    # Persist statement snapshot
    Repo.insert!(%VmuCore.CMS.Statement{
      account_id:     id,
      statement_date: eod_date,
      closing_balance: total_due,
      minimum_payment: min_payment,
      due_date:        next_due_date,
      retail_balance:  bucket.retail_balance,
      cash_balance:    bucket.cash_balance,
      accrued_interest: bucket.accrued_interest,
      unpaid_fees:     bucket.unpaid_fees
    })

    # Update account with next statement date
    Repo.update_all(
      from(a in Account, where: a.account_id == ^id),
      set: [next_statement_date: Date.add(eod_date, 30), minimum_payment: min_payment]
    )
    :ok
  end

  # VisionPlus minimum payment: higher of floor amount or percentage of balance
  defp calculate_minimum(total_due, account, _bucket) do
    case ParameterEngine.get(account.sys_id, account.bank_id, account.logo_id, account.block_id, :min_payment_percent) do
      {:ok, pct} ->
        pct_amount = Decimal.mult(total_due, Decimal.div(pct, Decimal.new("100")))
        floor      = Decimal.new("50.00")  # AED 50 floor; load from block_parameters
        Decimal.max(pct_amount, floor)

      {:error, _} ->
        Decimal.new("50.00")
    end
  end
end
```

### `lib/vmu_core/cms/repayment_distributor.ex`
```elixir
defmodule VmuCore.CMS.RepaymentDistributor do
  @moduledoc """
  Distributes a cardholder payment across balance buckets in VisionPlus priority order:
    1. Unpaid fees (highest priority — regulatory in many markets)
    2. Accrued interest
    3. Cash advance principal
    4. Retail principal (lowest priority)
  """
  alias VmuCore.{Repo, CMS.BalanceBucket, CMS.InternalGlPoster}

  def distribute(account_id, payment_amount, reference, payment_date) do
    bucket = Repo.get_by!(BalanceBucket, account_id: account_id)

    {remaining, allocations} =
      [{:unpaid_fees, "FEE"}, {:accrued_interest, "INTEREST"},
       {:cash_balance, "CASH"}, {:retail_balance, "RETAIL"}]
      |> Enum.reduce({payment_amount, []}, fn {field, bucket_name}, {rem, allocs} ->
        current = Map.get(bucket, field)
        applied = Decimal.min(rem, current)

        if Decimal.compare(applied, Decimal.new("0")) == :gt do
          {Decimal.sub(rem, applied), [{field, bucket_name, applied} | allocs]}
        else
          {rem, allocs}
        end
      end)

    # Apply allocations in a transaction
    Repo.transaction(fn ->
      Enum.each(allocations, fn {field, bucket_name, amount} ->
        new_value = Decimal.sub(Map.get(bucket, field), amount)
        Repo.update_all(
          from(b in BalanceBucket, where: b.account_id == ^account_id),
          set: [{field, new_value}]
        )
        InternalGlPoster.post_payment(account_id, amount, "#{reference}:#{bucket_name}", payment_date)
      end)

      # Update OTB
      total_applied = Decimal.sub(payment_amount, remaining)
      Repo.update_all(
        from(a in VmuCore.CMS.Account, where: a.account_id == ^account_id),
        inc: [open_to_buy: total_applied]
      )
    end)
  end
end
```

---

## Task 12 — CTA EmbossingFileGenerator + CardOrderManager

### Migration: `cta_card_orders` + `cta_card_stock`
```sql
CREATE TABLE cta_card_orders (
    order_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sys_id          VARCHAR(4)  NOT NULL,
    logo_id         VARCHAR(4)  NOT NULL,
    bureau_code     VARCHAR(20) NOT NULL,   -- personalization bureau identifier
    quantity        INTEGER     NOT NULL,
    status          VARCHAR(20) NOT NULL DEFAULT 'PENDING',  -- PENDING, SENT, ACKNOWLEDGED, RECEIVED
    embossing_file  TEXT,                   -- file path / S3 key of the generated embossing file
    sent_at         TIMESTAMP,
    acknowledged_at TIMESTAMP,
    received_at     TIMESTAMP,
    inserted_at     TIMESTAMP   NOT NULL DEFAULT NOW()
);

CREATE TABLE cta_card_stock (
    stock_id        UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sys_id          VARCHAR(4)  NOT NULL,
    logo_id         VARCHAR(4)  NOT NULL,
    branch_code     VARCHAR(20) NOT NULL,
    pan_range_start VARCHAR(19) NOT NULL,
    pan_range_end   VARCHAR(19) NOT NULL,
    total_quantity  INTEGER     NOT NULL DEFAULT 0,
    available       INTEGER     NOT NULL DEFAULT 0,
    reserved        INTEGER     NOT NULL DEFAULT 0,
    damaged         INTEGER     NOT NULL DEFAULT 0,
    inserted_at     TIMESTAMP   NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP   NOT NULL DEFAULT NOW()
);
```

### Bureau Adapter Behaviour
```elixir
defmodule VmuCore.CTA.BureauAdapter do
  @moduledoc "Behaviour for card personalization bureau integrations."

  @callback send_order(order :: map()) :: {:ok, acknowledgement_ref :: String.t()} | {:error, term()}
  @callback receive_stock(acknowledgement_ref :: String.t()) :: {:ok, items :: list()} | {:error, term()}
  @callback report_damaged(stock_id :: String.t(), quantity :: integer()) :: :ok | {:error, term()}
end
```

### Embossing file format (ISO 7813 track data):
```elixir
defmodule VmuCore.CTA.EmbossingFileGenerator do
  @moduledoc """
  Generates embossing (personalization) files for card bureaus.
  Each record contains: PAN, expiry, cardholder name, CVV2, service code, track 1/2 data.
  File format: fixed-width or CSV depending on bureau. Default: Thales/G+D ISO format.
  """

  def generate(accounts) do
    records = Enum.map(accounts, &build_record/1)
    header  = build_header(length(records))
    footer  = build_footer(records)
    [header | records] ++ [footer]
    |> Enum.join("\n")
  end

  defp build_record(%{pan: pan, expiry: expiry, name: name, cvv2: cvv2}) do
    track1 = "%B#{pan}^#{format_name(name)}^#{expiry}101#{cvv2}000000000000000?"
    track2 = ";#{pan}=#{expiry}101#{cvv2}0000000000000?"
    "#{String.pad_trailing(pan, 19)}#{expiry}#{String.pad_trailing(name, 26)}#{cvv2}#{track1}#{track2}"
  end

  defp format_name(name) do
    name
    |> String.upcase()
    |> String.replace(~r/[^A-Z ]/, "")
    |> String.slice(0, 26)
  end

  defp build_header(count), do: "HDR#{Date.utc_today() |> Date.to_iso8601() |> String.replace("-", "")}#{String.pad_leading("#{count}", 8, "0")}"
  defp build_footer(records), do: "TRL#{String.pad_leading("#{length(records)}", 8, "0")}"
end
```

---

## Task 13 — StockInventoryManager

```elixir
defmodule VmuCore.CTA.StockInventoryManager do
  alias VmuCore.{Repo, CTA.CardStock}
  import Ecto.Query

  def receive_stock(sys_id, logo_id, branch_code, pan_range_start, pan_range_end, quantity) do
    case Repo.get_by(CardStock, sys_id: sys_id, logo_id: logo_id, branch_code: branch_code) do
      nil ->
        Repo.insert!(%CardStock{
          sys_id: sys_id, logo_id: logo_id, branch_code: branch_code,
          pan_range_start: pan_range_start, pan_range_end: pan_range_end,
          total_quantity: quantity, available: quantity, reserved: 0, damaged: 0
        })

      stock ->
        Repo.update_all(
          from(s in CardStock, where: s.stock_id == ^stock.stock_id),
          inc: [total_quantity: quantity, available: quantity]
        )
    end
    :ok
  end

  def reserve_card(stock_id) do
    case Repo.update_all(
      from(s in CardStock, where: s.stock_id == ^stock_id and s.available > 0),
      inc: [available: -1, reserved: 1]
    ) do
      {1, _} -> :ok
      {0, _} -> {:error, :no_stock_available}
    end
  end

  def report_damaged(stock_id, quantity) do
    Repo.update_all(
      from(s in CardStock, where: s.stock_id == ^stock_id),
      inc: [available: -quantity, damaged: quantity]
    )
    :ok
  end

  def available_stock(sys_id, logo_id) do
    Repo.all(from s in CardStock,
      where: s.sys_id == ^sys_id and s.logo_id == ^logo_id and s.available > 0,
      select: {s.branch_code, s.available})
  end
end
```

---

## Task 14 — HSM PinIssuanceService

PIN issuance happens at card creation. The PIN block is generated by the HSM and stored encrypted. The cardholder receives the PIN via mailer or IVR retrieval (never plaintext over API).

```elixir
defmodule VmuCore.CTA.PinIssuanceService do
  @moduledoc """
  Manages PIN issuance for new cards and PIN change for existing cards.
  Delegates all cryptographic operations to SoftHSM (already in muNSwitch).

  PIN storage: only the encrypted PIN block (ISO FORMAT-0, T-DES) is stored.
  The clear PIN never exists outside the HSM boundary.
  """

  alias DaProductApp.SoftHSM

  @doc "Generate and store an initial PIN for a newly issued card."
  def issue_pin(pan, account_id) do
    with {:ok, pin_block} <- SoftHSM.generate_pin_block(pan),
         {:ok, _}         <- store_encrypted_pin(account_id, pin_block) do
      # Return pin_block for inclusion in PIN mailer (encrypted to mailer key)
      {:ok, pin_block}
    end
  end

  @doc "Verify a PIN presented during authorization or IVR."
  def verify_pin(pan, account_id, presented_pin_block) do
    with {:ok, stored_pin_block} <- get_stored_pin(account_id) do
      SoftHSM.verify_pin_block(pan, presented_pin_block, stored_pin_block)
    end
  end

  @doc "Change a PIN (IVR or ATM-initiated)."
  def change_pin(pan, account_id, new_pin_block) do
    with :ok <- SoftHSM.validate_pin_block(pan, new_pin_block),
         {:ok, _} <- store_encrypted_pin(account_id, new_pin_block) do
      :ok
    end
  end

  defp store_encrypted_pin(account_id, pin_block) do
    VmuCore.Repo.insert(
      %VmuCore.CTA.PinRecord{account_id: account_id, encrypted_pin_block: pin_block},
      on_conflict: :replace_all,
      conflict_target: :account_id
    )
  end

  defp get_stored_pin(account_id) do
    case VmuCore.Repo.get_by(VmuCore.CTA.PinRecord, account_id: account_id) do
      nil    -> {:error, :no_pin_set}
      record -> {:ok, record.encrypted_pin_block}
    end
  end
end
```

---

## Task 15 — Card Activation Workflow

Card activation links the physical plastic (CTA domain) to the account (CMS domain).

```elixir
defmodule VmuCore.CMS.CardActivationService do
  @moduledoc """
  Activates a card when the cardholder completes the activation step.
  Can be triggered via: IVR, cardholder portal, ATM first-use, or bank branch.

  Steps:
    1. Verify the activation code matches what was generated at issuance
    2. Verify the card is in INACTIVE (pending activation) status
    3. Update CMS account_status to ACTIVE
    4. Update CTA stock record: reserved → issued
    5. Notify AccountStateCoordinator to refresh its in-memory state
  """

  alias VmuCore.{Repo, CMS.Account, CMS.AccountStateCoordinator, CTA.StockInventoryManager}
  import Ecto.Query

  def activate(account_id, activation_code, stock_id) do
    Repo.transaction(fn ->
      with :ok              <- verify_activation_code(account_id, activation_code),
           {:ok, _account}  <- set_account_active(account_id),
           :ok              <- mark_card_issued(stock_id) do
        # Tell the in-memory coordinator to pick up the new status
        AccountStateCoordinator.refresh(account_id)
        :ok
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp verify_activation_code(account_id, code) do
    case Repo.get_by(VmuCore.CTA.ActivationCode, account_id: account_id, code: code, used: false) do
      nil    -> {:error, :invalid_activation_code}
      record ->
        Repo.update_all(from(a in VmuCore.CTA.ActivationCode, where: a.id == ^record.id), set: [used: true])
        :ok
    end
  end

  defp set_account_active(account_id) do
    case Repo.update_all(
      from(a in Account, where: a.account_id == ^account_id and a.account_status == "INACTIVE"),
      set: [account_status: "ACTIVE"]
    ) do
      {1, _} -> {:ok, :activated}
      {0, _} -> {:error, :already_active_or_not_found}
    end
  end

  defp mark_card_issued(stock_id) do
    Repo.update_all(
      from(s in VmuCore.CTA.CardStock, where: s.stock_id == ^stock_id),
      inc: [reserved: -1]
    )
    :ok
  end
end
```

---

## Phase 2 Done Criteria

- [ ] `cms_ledger_entries` migration applied; `InternalGlPoster.post_purchase/4` inserts idempotently
- [ ] `block_parameters.velocity_matrix` JSONB column in place; `VelocityChecker.check/8` returns `:ok` within limits and `{:exceeded, ...}` beyond
- [ ] `InterestEngine.accrue_interest/9` produces correct interest charge for a known ADB scenario (verified with Decimal arithmetic, not float)
- [ ] EOD Oban `Coordinator` enqueues one `AccountJob` per account in tonight's cycle
- [ ] `AccountJob` runs all 6 steps; a crash mid-run unlocks the account on retry
- [ ] `StatementGenerator.generate/2` persists a `cms_statements` record with correct minimum payment
- [ ] `RepaymentDistributor.distribute/4` allocates payment to buckets in priority order (fees first)
- [ ] CTA embossing file generates valid track 1 + track 2 data for a test card
- [ ] `StockInventoryManager.receive_stock/6` increases available count; `reserve_card/1` decrements it
- [ ] `PinIssuanceService.issue_pin/2` calls SoftHSM and stores an encrypted PIN block
- [ ] `CardActivationService.activate/3` transitions account from INACTIVE to ACTIVE and refreshes AccountStateCoordinator
