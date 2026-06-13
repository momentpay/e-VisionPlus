# Phase 8 — ITS Interchange Tracking System + IVR Module Rename
## Implementation Specification

**Repository:** `vmu_core`  
**New module namespace:** `VmuCore.ITS` (canonical VisionPlus ITS — Interchange Tracking System)  
**IVR rename:** `VmuCore.ITS` → `VmuCore.IVR` (prerequisite step)  
**VisionPlus reference:** ITS batch cycle (ITS1 → TRAMS → ITS2), copy requests, chargeback feed  
**Status:** PLANNED  
**Prerequisite:** Phase 6 and Phase 7 complete; IVR module rename must happen before Phase 8 begins

---

## 1. Overview

**VisionPlus ITS (Interchange Tracking System)** manages the paper trail between the issuer and the card schemes (Mastercard, Visa) for:

- **Copy requests** — requests for transaction documentation sent to the acquiring side
- **Retrieval requests** — formal requests for transaction slips (T&E, dispute evidence)
- **Chargeback initiation** — the ITS1 batch extracts chargeback data from CMS and routes it to TRAMS for scheme submission
- **Incoming chargeback/retrieval responses** — ITS2 receives responses from TRAMS/schemes and routes them back to CMS/DPS
- **Interchange fee claims** — tracks fees billed and received on interchange transactions
- **Financial Adjustment Records (FARs)** — scheme-generated adjustments for misrouted transactions, processing errors, or compliance failures

In the VisionPlus batch cycle:
```
ITS1 → TRAMS → ITS2
```
- **ITS1**: Extract chargeback/retrieval requests from CMS → feed into TRAMS for scheme network submission
- **TRAMS**: Routes to Mastercard IPM / Visa Base II
- **ITS2**: Receive incoming scheme responses → route back to ITS → update DPS dispute records

---

## 2. Difference from Current vMu ITS Module

| | Current `VmuCore.ITS` (to be renamed) | New `VmuCore.ITS` (this phase) |
|---|---|---|
| **Name** | Interactive Telephone System (IVR) | Interchange Tracking System |
| **Function** | OTP engine, IVR session GenServer | Copy requests, chargeback feed, fee claims |
| **Tables** | (none — in-memory only) | `its_copy_requests`, `its_fee_claims`, `its_financial_adjustments` |
| **Batch role** | None | ITS1 (extract) + ITS2 (receive) in daily batch cycle |

---

## 3. Step 0 — IVR Module Rename (Must Do First)

Before implementing the new ITS, rename all references to the old IVR module:

### Files to rename

| Old path | New path |
|----------|----------|
| `lib/vmu_core/its/ivr_session.ex` | `lib/vmu_core/ivr/ivr_session.ex` |
| `lib/vmu_core/its/otp_engine.ex` | `lib/vmu_core/ivr/otp_engine.ex` |

### Module name changes

| Old | New |
|-----|-----|
| `VmuCore.ITS.IvrSession` | `VmuCore.IVR.IvrSession` |
| `VmuCore.ITS.OtpEngine` | `VmuCore.IVR.OtpEngine` |
| `VmuCore.ITS.SessionRegistry` | `VmuCore.IVR.SessionRegistry` |

### application.ex change

```elixir
# Old (also has the G3 supervision bug — fix both at once):
# ← VmuCore.ITS.SessionRegistry was never started

# New — add to children list BEFORE Horde:
{Registry, keys: :unique, name: VmuCore.IVR.SessionRegistry}
```

### CTA reference update

`cta/card_activation.ex` calls the IVR session for first-use activation. Update:
```elixir
# Old:
VmuCore.ITS.IvrSession.start_link(session_id)
# New:
VmuCore.IVR.IvrSession.start_link(session_id)
```

### phase-tracker.md + verification report

Update ITS module entry in compatibility summary to reflect both modules:
- `VmuCore.IVR` — OTP, IVR session (renamed, G15 resolved)
- `VmuCore.ITS` — Interchange Tracking (new, Phase 8)

---

## 4. Database Schema (new ITS tables)

### 4.1 `its_copy_requests`

A copy request is a formal request from the issuer for documentation of a transaction (e.g., sales slip, authorization log) sent to the acquirer via the card scheme.

```sql
CREATE TABLE its_copy_requests (
  id                  BIGSERIAL PRIMARY KEY,
  dispute_id          BIGINT         REFERENCES dps_disputes(id),    -- link to DPS if dispute-driven
  account_id          BIGINT         NOT NULL REFERENCES cms_accounts(id),
  card_number_token   VARCHAR(64)    NOT NULL,                        -- SHA-256 PAN token
  transaction_date    DATE           NOT NULL,
  transaction_amount  NUMERIC(18,2)  NOT NULL,
  currency            CHAR(3)        NOT NULL DEFAULT 'AED',
  merchant_name       VARCHAR(100),
  merchant_id         VARCHAR(20),
  acquirer_bin        VARCHAR(11),
  network             VARCHAR(10)    NOT NULL,                        -- 'MASTERCARD' | 'VISA'
  arn                 VARCHAR(24),                                    -- Acquirer Reference Number
  request_type        VARCHAR(20)    NOT NULL,
    -- 'COPY_REQUEST' | 'RETRIEVAL_REQUEST' | 'INQUIRY'
  request_reason      VARCHAR(50),
  status              VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
    -- 'PENDING' | 'SENT' | 'FULFILLED' | 'DECLINED' | 'EXPIRED' | 'CANCELLED'
  sent_at             TIMESTAMPTZ,
  fulfilled_at        TIMESTAMPTZ,
  response_reason     VARCHAR(100),
  deadline_date       DATE,                                           -- scheme SLA deadline
  its1_batch_date     DATE,                                           -- date extracted in ITS1
  its2_batch_date     DATE,                                           -- date response received
  idempotency_key     VARCHAR(64)    UNIQUE,
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX its_copy_requests_account ON its_copy_requests(account_id, status);
CREATE INDEX its_copy_requests_its1 ON its_copy_requests(its1_batch_date) WHERE its1_batch_date IS NOT NULL;
CREATE INDEX its_copy_requests_dispute ON its_copy_requests(dispute_id) WHERE dispute_id IS NOT NULL;
```

### 4.2 `its_fee_claims`

Interchange fee claims track the interchange income and expense per clearing transaction.

```sql
CREATE TABLE its_fee_claims (
  id                  BIGSERIAL PRIMARY KEY,
  clearing_record_id  BIGINT         REFERENCES trams_clearing_records(id),
  network             VARCHAR(10)    NOT NULL,                        -- 'MASTERCARD' | 'VISA'
  claim_type          VARCHAR(20)    NOT NULL,
    -- 'INTERCHANGE_INCOME' | 'INTERCHANGE_EXPENSE' | 'SCHEME_FEE' | 'PROCESSING_FEE'
  mcc                 VARCHAR(4),
  interchange_category VARCHAR(20),                                   -- e.g., 'CONSUMER_CREDIT_STANDARD'
  gross_amount        NUMERIC(18,2)  NOT NULL,                        -- original transaction amount
  interchange_rate    NUMERIC(8,6)   NOT NULL,                        -- e.g., 0.016500
  interchange_amount  NUMERIC(18,2)  NOT NULL,                        -- gross × rate
  scheme_fee_amount   NUMERIC(18,2)  NOT NULL DEFAULT 0,
  net_interchange     NUMERIC(18,2)  NOT NULL,                        -- interchange_amount - scheme_fee
  currency            CHAR(3)        NOT NULL DEFAULT 'AED',
  processing_date     DATE           NOT NULL,
  settlement_date     DATE,
  status              VARCHAR(20)    NOT NULL DEFAULT 'PENDING',
    -- 'PENDING' | 'SETTLED' | 'DISPUTED' | 'REVERSED'
  gl_entry_id         BIGINT,
  idempotency_key     VARCHAR(64)    UNIQUE,
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX its_fee_claims_clearing ON its_fee_claims(clearing_record_id);
CREATE INDEX its_fee_claims_settlement ON its_fee_claims(settlement_date, status);
```

### 4.3 `its_financial_adjustments`

Scheme-generated Financial Adjustment Records (FARs) — corrections to interchange, misrouted transactions, compliance failures.

```sql
CREATE TABLE its_financial_adjustments (
  id                  BIGSERIAL PRIMARY KEY,
  network             VARCHAR(10)    NOT NULL,
  adjustment_type     VARCHAR(30)    NOT NULL,
    -- 'MISROUTING' | 'PROCESSING_ERROR' | 'COMPLIANCE' | 'INTERCHANGE_CORRECTION'
  reference_no        VARCHAR(30)    NOT NULL UNIQUE,                 -- scheme-assigned reference
  original_clearing_id BIGINT        REFERENCES trams_clearing_records(id),
  original_txn_date   DATE,
  adjustment_amount   NUMERIC(18,2)  NOT NULL,                        -- positive = income, negative = expense
  currency            CHAR(3)        NOT NULL DEFAULT 'AED',
  reason_code         VARCHAR(10),
  reason_description  VARCHAR(200),
  received_date       DATE           NOT NULL,
  applied_date        DATE,
  status              VARCHAR(20)    NOT NULL DEFAULT 'RECEIVED',
    -- 'RECEIVED' | 'UNDER_REVIEW' | 'ACCEPTED' | 'DISPUTED' | 'REVERSED'
  gl_entry_id         BIGINT,
  inserted_at         TIMESTAMPTZ    NOT NULL DEFAULT NOW(),
  updated_at          TIMESTAMPTZ    NOT NULL DEFAULT NOW()
);

CREATE INDEX its_financial_adjustments_network ON its_financial_adjustments(network, received_date);
CREATE INDEX its_financial_adjustments_status ON its_financial_adjustments(status);
```

---

## 5. Elixir Modules

### 5.1 `VmuCore.ITS.CopyRequestManager`

```elixir
defmodule VmuCore.ITS.CopyRequestManager do
  alias VmuCore.ITS.CopyRequest
  alias VmuCore.DPS.Dispute
  alias VmuCore.Repo

  @mastercard_deadline_days 45
  @visa_deadline_days       30

  @doc """
  Raises a copy/retrieval request. Can be called:
  - From DPS when a dispute is filed and documentation is needed
  - Directly from OperatorPortal for non-dispute inquiries
  """
  def raise_request(attrs) do
    deadline = calculate_deadline(attrs.network, Date.utc_today())

    %CopyRequest{}
    |> CopyRequest.changeset(Map.merge(attrs, %{
      status:           "PENDING",
      deadline_date:    deadline,
      idempotency_key:  "copy_#{attrs.account_id}_#{attrs.transaction_date}_#{attrs.arn}"
    }))
    |> Repo.insert(on_conflict: :nothing)
  end

  defp calculate_deadline("MASTERCARD", from_date), do: Date.add(from_date, @mastercard_deadline_days)
  defp calculate_deadline("VISA", from_date),        do: Date.add(from_date, @visa_deadline_days)
  defp calculate_deadline(_, from_date),             do: Date.add(from_date, 30)

  @doc """
  Marks a copy request as FULFILLED when the response arrives in ITS2 batch.
  Updates the linked DPS dispute to RETRIEVAL_REQUESTED → next state.
  """
  def mark_fulfilled(request_id, response_attrs) do
    Repo.transaction(fn ->
      request = Repo.get!(CopyRequest, request_id)

      request
      |> CopyRequest.changeset(%{
        status:       "FULFILLED",
        fulfilled_at: DateTime.utc_now(),
        response_reason: response_attrs[:reason],
        its2_batch_date: Date.utc_today()
      })
      |> Repo.update!()

      # Advance the linked DPS dispute if present
      if request.dispute_id do
        advance_dispute(request.dispute_id)
      end
    end)
  end

  defp advance_dispute(dispute_id) do
    dispute = Repo.get!(Dispute, dispute_id)
    if dispute.status == "RETRIEVAL_REQUESTED" do
      dispute
      |> Dispute.changeset(%{status: "CHARGEBACK_FILED"})
      |> Repo.update!()
    end
  end

  @doc """
  Marks expired requests (deadline_date < today, still SENT).
  Called from ITS2 batch job.
  """
  def expire_overdue do
    today = Date.utc_today()

    Repo.update_all(
      from(r in CopyRequest,
        where: r.status == "SENT"
          and r.deadline_date < ^today
      ),
      set: [status: "EXPIRED", updated_at: DateTime.utc_now()]
    )
  end
end
```

### 5.2 `VmuCore.ITS.FeeClaimProcessor`

```elixir
defmodule VmuCore.ITS.FeeClaimProcessor do
  alias VmuCore.ITS.FeeClaim
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.Repo
  import Decimal, as: D

  @doc """
  Creates an interchange fee claim for a matched clearing record.
  Called from VmuCore.TRAMS.MastercardIpm / VisaBaseIi after matching.
  Looks up the interchange rate from ParameterEngine using network + MCC.
  """
  def create_claim(clearing_record) do
    rate = lookup_interchange_rate(clearing_record.network, clearing_record.mcc)
    scheme_fee = lookup_scheme_fee(clearing_record.network)

    interchange_amount = D.mult(D.new(clearing_record.amount), rate)
    scheme_fee_amount  = D.mult(D.new(clearing_record.amount), scheme_fee)
    net_interchange    = D.sub(interchange_amount, scheme_fee_amount)

    idempotency_key = "fee_#{clearing_record.id}"

    %FeeClaim{}
    |> FeeClaim.changeset(%{
      clearing_record_id:   clearing_record.id,
      network:              clearing_record.network,
      claim_type:           "INTERCHANGE_INCOME",
      mcc:                  clearing_record.mcc,
      gross_amount:         clearing_record.amount,
      interchange_rate:     rate,
      interchange_amount:   interchange_amount,
      scheme_fee_amount:    scheme_fee_amount,
      net_interchange:      net_interchange,
      currency:             clearing_record.currency,
      processing_date:      Date.utc_today(),
      status:               "PENDING",
      idempotency_key:      idempotency_key
    })
    |> Repo.insert(on_conflict: :nothing)
    |> case do
      {:ok, claim} ->
        post_interchange_gl(claim)
        {:ok, claim}
      {:error, _} = err ->
        err
    end
  end

  defp lookup_interchange_rate(network, mcc) do
    key = "its_interchange_rate_#{String.downcase(network)}_#{mcc}"
    ParameterEngine.get(key, default: "0.0165") |> D.new()
  end

  defp lookup_scheme_fee(network) do
    key = "its_scheme_fee_#{String.downcase(network)}"
    ParameterEngine.get(key, default: "0.0010") |> D.new()
  end

  defp post_interchange_gl(claim) do
    # DR: Interchange Receivable / CR: Interchange Income
    InternalGlPoster.post(%{
      debit_account:  "its_interchange_recv",
      credit_account: "its_interchange_income",
      amount:         claim.net_interchange,
      description:    "Interchange #{claim.network} clearing #{claim.clearing_record_id}",
      entry_id:       "its_fee_#{claim.id}"
    })
  end

  @doc """
  Settles all PENDING claims up to the settlement date.
  Called from the ITS settlement Oban job.
  """
  def settle_claims(settlement_date) do
    claims =
      from(f in FeeClaim,
        where: f.status == "PENDING"
          and f.processing_date <= ^settlement_date
      )
      |> Repo.all()

    Enum.each(claims, fn claim ->
      Repo.update_all(
        from(f in FeeClaim, where: f.id == ^claim.id),
        set: [status: "SETTLED", settlement_date: settlement_date]
      )
    end)

    total = Enum.reduce(claims, D.new(0), &D.add(&1.net_interchange, &2))
    {:ok, %{settled_count: length(claims), total_settled: total}}
  end
end
```

### 5.3 `VmuCore.ITS.FinancialAdjustmentProcessor`

```elixir
defmodule VmuCore.ITS.FinancialAdjustmentProcessor do
  alias VmuCore.ITS.FinancialAdjustment
  alias VmuCore.CMS.InternalGlPoster
  alias VmuCore.Repo

  @doc """
  Ingests a Financial Adjustment Record (FAR) received from scheme.
  Called from ITS2 batch processor when FAR records are in the incoming file.
  """
  def ingest_far(far_attrs) do
    %FinancialAdjustment{}
    |> FinancialAdjustment.changeset(Map.merge(far_attrs, %{
      status:        "RECEIVED",
      received_date: Date.utc_today()
    }))
    |> Repo.insert(on_conflict: :nothing, conflict_target: :reference_no)
  end

  @doc """
  Accepts and applies an FAR — posts GL entry and marks applied.
  """
  def accept(adjustment_id) do
    Repo.transaction(fn ->
      adj = Repo.get!(FinancialAdjustment, adjustment_id)

      gl_account =
        if Decimal.gt?(adj.adjustment_amount, Decimal.new(0)) do
          %{debit: "its_far_recv", credit: "its_far_income"}
        else
          %{debit: "its_far_expense", credit: "its_far_payable"}
        end

      {:ok, gl_entry} = InternalGlPoster.post(%{
        debit_account:  gl_account.debit,
        credit_account: gl_account.credit,
        amount:         Decimal.abs(adj.adjustment_amount),
        description:    "FAR #{adj.reference_no} #{adj.adjustment_type}",
        entry_id:       "its_far_#{adj.id}"
      })

      adj
      |> FinancialAdjustment.changeset(%{
        status:      "ACCEPTED",
        applied_date: Date.utc_today(),
        gl_entry_id:  gl_entry.id
      })
      |> Repo.update!()
    end)
  end
end
```

### 5.4 `VmuCore.ITS.Batch.Its1Extractor`

ITS1 batch — extracts pending chargeback and copy requests from CMS/DPS and prepares them for TRAMS submission.

```elixir
defmodule VmuCore.ITS.Batch.Its1Extractor do
  alias VmuCore.ITS.CopyRequest
  alias VmuCore.DPS.Dispute
  alias VmuCore.Repo
  import Ecto.Query

  @doc """
  ITS1 batch step: extract all PENDING copy requests and CHARGEBACK_FILED disputes
  for submission to TRAMS (and onward to the scheme networks).

  In VisionPlus this produces an output file; in vMu it directly enqueues
  TRAMS processing jobs and marks records as SENT.
  """
  def run(batch_date) do
    extract_copy_requests(batch_date)
    extract_chargebacks(batch_date)
  end

  defp extract_copy_requests(batch_date) do
    pending_requests =
      from(r in CopyRequest,
        where: r.status == "PENDING",
        preload: [:account]
      )
      |> Repo.all()

    Enum.each(pending_requests, fn request ->
      # Build scheme submission record and enqueue in TRAMS
      submit_to_trams(request)

      Repo.update_all(
        from(r in CopyRequest, where: r.id == ^request.id),
        set: [status: "SENT", sent_at: DateTime.utc_now(), its1_batch_date: batch_date]
      )
    end)

    %{copy_requests_sent: length(pending_requests)}
  end

  defp extract_chargebacks(batch_date) do
    # Find disputes in CHARGEBACK_FILED state that have not yet been submitted
    chargeback_disputes =
      from(d in Dispute,
        where: d.status == "CHARGEBACK_FILED" and is_nil(d.submitted_at),
        preload: [:account]
      )
      |> Repo.all()

    Enum.each(chargeback_disputes, fn dispute ->
      # Create a copy request record for tracking
      VmuCore.ITS.CopyRequestManager.raise_request(%{
        dispute_id:         dispute.id,
        account_id:         dispute.account_id,
        card_number_token:  dispute.card_number_token,
        transaction_date:   dispute.transaction_date,
        transaction_amount: dispute.original_amount,
        network:            dispute.network || "MASTERCARD",
        arn:                dispute.arn,
        request_type:       "RETRIEVAL_REQUEST",
        request_reason:     "CHARGEBACK"
      })

      # Mark dispute as submitted
      Repo.update_all(
        from(d in Dispute, where: d.id == ^dispute.id),
        set: [submitted_at: DateTime.utc_now()]
      )
    end)

    %{chargebacks_submitted: length(chargeback_disputes)}
  end

  defp submit_to_trams(request) do
    # Enqueue an Oban job to send to the appropriate scheme network
    %{
      request_id: request.id,
      network:    request.network,
      arn:        request.arn,
      type:       request.request_type
    }
    |> VmuCore.TRAMS.Oban.SchemeSubmissionJob.new()
    |> Oban.insert()
  end
end
```

### 5.5 `VmuCore.ITS.Batch.Its2Receiver`

ITS2 batch — processes incoming responses from TRAMS/schemes (retrieval responses, chargeback acknowledgements, FARs).

```elixir
defmodule VmuCore.ITS.Batch.Its2Receiver do
  alias VmuCore.ITS.{CopyRequestManager, FinancialAdjustmentProcessor}
  alias VmuCore.ITS.FeeClaimProcessor

  @doc """
  ITS2 batch step: process all incoming scheme responses for the batch_date.
  In vMu these arrive as structured maps from TRAMS parsing.
  In VisionPlus this reads the ITS2 input file produced by TRAMS.
  """
  def run(batch_date, incoming_records) do
    results = Enum.map(incoming_records, &process_record(&1, batch_date))

    %{
      fulfilled:   Enum.count(results, &match?({:ok, :fulfilled}, &1)),
      declined:    Enum.count(results, &match?({:ok, :declined}, &1)),
      far_applied: Enum.count(results, &match?({:ok, :far}, &1)),
      errors:      Enum.count(results, &match?({:error, _}, &1))
    }
  end

  defp process_record(%{record_type: "COPY_RESPONSE", request_id: id} = record, batch_date) do
    case record.response_code do
      "00" ->
        CopyRequestManager.mark_fulfilled(id, %{reason: record[:reason]})
        {:ok, :fulfilled}
      code ->
        mark_declined(id, code)
        {:ok, :declined}
    end
  end

  defp process_record(%{record_type: "FAR"} = record, _batch_date) do
    case FinancialAdjustmentProcessor.ingest_far(%{
      network:           record.network,
      adjustment_type:   record.adjustment_type,
      reference_no:      record.reference_no,
      adjustment_amount: record.amount,
      reason_code:       record.reason_code,
      reason_description: record.reason_description,
      original_txn_date: record[:original_txn_date]
    }) do
      {:ok, far} ->
        # Auto-accept FARs below a threshold; queue for review above it
        if Decimal.abs(far.adjustment_amount) <= Decimal.new("1000") do
          FinancialAdjustmentProcessor.accept(far.id)
        end
        {:ok, :far}
      err -> err
    end
  end

  defp process_record(_unknown, _date), do: {:ok, :skipped}

  defp mark_declined(request_id, reason_code) do
    import Ecto.Query
    VmuCore.Repo.update_all(
      from(r in VmuCore.ITS.CopyRequest, where: r.id == ^request_id),
      set: [status: "DECLINED", response_reason: reason_code,
            its2_batch_date: Date.utc_today(), updated_at: DateTime.utc_now()]
    )
  end
end
```

---

## 6. Oban Jobs

### 6.1 `VmuCore.ITS.Oban.Its1BatchJob`

```elixir
defmodule VmuCore.ITS.Oban.Its1BatchJob do
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_date" => date_str}}) do
    batch_date = Date.from_iso8601!(date_str)
    VmuCore.ITS.Batch.Its1Extractor.run(batch_date)
    :ok
  end
end
```

Cron: runs in **Phase 1** of batch cycle (before CMS1).
```elixir
%{cron: "0 21 * * *", worker: "VmuCore.ITS.Oban.Its1BatchJob",
  args: %{batch_date: "<%= Date.to_iso8601(Date.utc_today()) %>"}}
```

### 6.2 `VmuCore.ITS.Oban.Its2BatchJob`

```elixir
defmodule VmuCore.ITS.Oban.Its2BatchJob do
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"batch_date" => date_str}}) do
    batch_date = Date.from_iso8601!(date_str)
    # In production: read scheme response file from SFTP / MQ
    # For now: process any pending TRAMS responses that have been decoded
    incoming = VmuCore.TRAMS.ResponseQueue.fetch_pending(batch_date)
    VmuCore.ITS.Batch.Its2Receiver.run(batch_date, incoming)
    :ok
  end
end
```

Cron: runs in **Phase 4** of batch cycle (after TRAMS clearing is complete).
```elixir
%{cron: "0 2 * * *", worker: "VmuCore.ITS.Oban.Its2BatchJob",
  args: %{batch_date: "<%= Date.to_iso8601(Date.utc_today()) %>"}}
```

### 6.3 `VmuCore.ITS.Oban.FeeSettlementJob`

```elixir
defmodule VmuCore.ITS.Oban.FeeSettlementJob do
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"settlement_date" => date_str}}) do
    settlement_date = Date.from_iso8601!(date_str)
    VmuCore.ITS.FeeClaimProcessor.settle_claims(settlement_date)
    :ok
  end
end
```

Cron: runs monthly (or per scheme settlement cycle).
```elixir
%{cron: "0 6 1 * *", worker: "VmuCore.ITS.Oban.FeeSettlementJob",
  args: %{settlement_date: "<%= Date.to_iso8601(Date.utc_today()) %>"}}
```

### 6.4 `VmuCore.ITS.Oban.CopyRequestExpiryJob`

```elixir
defmodule VmuCore.ITS.Oban.CopyRequestExpiryJob do
  use Oban.Worker, queue: :its, max_attempts: 3

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    VmuCore.ITS.CopyRequestManager.expire_overdue()
    :ok
  end
end
```

Cron: daily.
```elixir
%{cron: "30 6 * * *", worker: "VmuCore.ITS.Oban.CopyRequestExpiryJob", args: %{}}
```

---

## 7. GL Account Codes (ITS-specific)

| Code | Name | Usage |
|------|------|-------|
| `its_interchange_recv` | Interchange Receivable | DR on interchange income claim creation |
| `its_interchange_income` | Interchange Income | CR on interchange income claim creation |
| `its_interchange_expense` | Interchange Expense | DR when issuer pays interchange out |
| `its_interchange_payable` | Interchange Payable | CR when issuer owes interchange |
| `its_far_recv` | FAR Receivable | DR on positive FAR application |
| `its_far_income` | FAR Income | CR on positive FAR application |
| `its_far_expense` | FAR Expense | DR on negative FAR application |
| `its_far_payable` | FAR Payable | CR on negative FAR application |

---

## 8. Migration

```elixir
# priv/repo/migrations/20260616000001_create_its_tables.exs
defmodule VmuCore.Repo.Migrations.CreateItsTables do
  use Ecto.Migration

  def change do
    # Add submitted_at to dps_disputes (needed for ITS1 chargeback extraction)
    alter table(:dps_disputes) do
      add_if_not_exists :submitted_at, :utc_datetime
      add_if_not_exists :arn,          :string, size: 24
      add_if_not_exists :network,      :string, size: 10
    end

    create table(:its_copy_requests) do
      add :dispute_id,          references(:dps_disputes, on_delete: :nilify_all)
      add :account_id,          references(:cms_accounts, on_delete: :restrict), null: false
      add :card_number_token,   :string, size: 64, null: false
      add :transaction_date,    :date, null: false
      add :transaction_amount,  :decimal, precision: 18, scale: 2, null: false
      add :currency,            :string, size: 3, null: false, default: "AED"
      add :merchant_name,       :string, size: 100
      add :merchant_id,         :string, size: 20
      add :acquirer_bin,        :string, size: 11
      add :network,             :string, size: 10, null: false
      add :arn,                 :string, size: 24
      add :request_type,        :string, size: 20, null: false
      add :request_reason,      :string, size: 50
      add :status,              :string, size: 20, null: false, default: "PENDING"
      add :sent_at,             :utc_datetime
      add :fulfilled_at,        :utc_datetime
      add :response_reason,     :string, size: 100
      add :deadline_date,       :date
      add :its1_batch_date,     :date
      add :its2_batch_date,     :date
      add :idempotency_key,     :string, size: 64
      timestamps(type: :utc_datetime)
    end
    create unique_index(:its_copy_requests, [:idempotency_key])
    create index(:its_copy_requests, [:account_id, :status])
    create index(:its_copy_requests, [:dispute_id])
    create index(:its_copy_requests, [:its1_batch_date])

    create table(:its_fee_claims) do
      add :clearing_record_id,  references(:trams_clearing_records, on_delete: :restrict)
      add :network,             :string, size: 10, null: false
      add :claim_type,          :string, size: 20, null: false
      add :mcc,                 :string, size: 4
      add :interchange_category, :string, size: 20
      add :gross_amount,        :decimal, precision: 18, scale: 2, null: false
      add :interchange_rate,    :decimal, precision: 8, scale: 6, null: false
      add :interchange_amount,  :decimal, precision: 18, scale: 2, null: false
      add :scheme_fee_amount,   :decimal, precision: 18, scale: 2, null: false, default: "0"
      add :net_interchange,     :decimal, precision: 18, scale: 2, null: false
      add :currency,            :string, size: 3, null: false, default: "AED"
      add :processing_date,     :date, null: false
      add :settlement_date,     :date
      add :status,              :string, size: 20, null: false, default: "PENDING"
      add :gl_entry_id,         :bigint
      add :idempotency_key,     :string, size: 64
      add :inserted_at,         :utc_datetime, null: false
    end
    create unique_index(:its_fee_claims, [:idempotency_key])
    create index(:its_fee_claims, [:clearing_record_id])
    create index(:its_fee_claims, [:settlement_date, :status])

    create table(:its_financial_adjustments) do
      add :network,              :string, size: 10, null: false
      add :adjustment_type,      :string, size: 30, null: false
      add :reference_no,         :string, size: 30, null: false
      add :original_clearing_id, references(:trams_clearing_records, on_delete: :nilify_all)
      add :original_txn_date,    :date
      add :adjustment_amount,    :decimal, precision: 18, scale: 2, null: false
      add :currency,             :string, size: 3, null: false, default: "AED"
      add :reason_code,          :string, size: 10
      add :reason_description,   :string, size: 200
      add :received_date,        :date, null: false
      add :applied_date,         :date
      add :status,               :string, size: 20, null: false, default: "RECEIVED"
      add :gl_entry_id,          :bigint
      timestamps(type: :utc_datetime)
    end
    create unique_index(:its_financial_adjustments, [:reference_no])
    create index(:its_financial_adjustments, [:network, :received_date])
    create index(:its_financial_adjustments, [:status])
  end
end
```

---

## 9. Batch Cycle Position (updated for vMu)

```
Phase 1 — ITS1 (21:00) — Its1BatchJob
  └─ Extract PENDING copy requests → mark SENT
  └─ Extract CHARGEBACK_FILED disputes → mark submitted

Phase 2 — TRAMS Clearing (21:30) — existing jobs
  └─ MastercardIpm, VisaBaseIi parsing + matching
  └─ FeeClaimProcessor.create_claim called per matched record

Phase 3 — CMS EOD (23:00) — existing Oban pipeline
  └─ LockAccounts → AccrueInterest → AgeBuckets → GenerateStatement → FlushGL

Phase 4 — ITS2 (02:00) — Its2BatchJob
  └─ Process incoming scheme responses
  └─ Fulfill / decline copy requests
  └─ Ingest FARs

Phase 5 — LMS Batch (02:30) — Phase 6 jobs
  └─ WarehouseAdvancement → PointsCalculation → AutoDisbursement
```

---

## 10. Oban Queue Addition

```elixir
config :vmu_core, Oban,
  queues: [
    default:  10,
    eod:       2,
    lms:       5,
    hcs:       3,
    its:       4,    # ← add this
    clearing:  4
  ]
```

---

## 11. Implementation Order

1. **Step 0 — IVR rename** — rename `lib/vmu_core/its/` → `lib/vmu_core/ivr/`, update all module names, fix `application.ex` supervision (simultaneously resolves G3 and G15)
2. **Migration** — 3 new ITS tables + alter `dps_disputes` (add `submitted_at`, `arn`, `network`)
3. **Schema modules** — `CopyRequest`, `FeeClaim`, `FinancialAdjustment`
4. **CopyRequestManager** — `raise_request/1`, `mark_fulfilled/2`, `expire_overdue/0`
5. **FeeClaimProcessor** — `create_claim/1`, `settle_claims/1`
6. **FinancialAdjustmentProcessor** — `ingest_far/1`, `accept/1`
7. **Its1Extractor** — `run/1` (extract copy requests + chargebacks)
8. **Its2Receiver** — `run/2` (process incoming responses + FARs)
9. **Oban jobs** — `Its1BatchJob`, `Its2BatchJob`, `FeeSettlementJob`, `CopyRequestExpiryJob`
10. **Wire fee claims** — add `FeeClaimProcessor.create_claim/1` call in `TRAMS.MastercardIpm` and `TRAMS.VisaBaseIi` after clearing record match
11. **Wire ITS1 trigger** — add `Its1BatchJob` to Oban cron schedule
12. **Integration tests** — copy request lifecycle, chargeback submission, FAR ingestion + auto-accept, fee claim creation + settlement

---

## 12. Fixes Resolved by Phase 8

| Gap | Resolution |
|-----|-----------|
| G3 — IVR SessionRegistry not supervised | Fixed in Step 0 (rename adds `VmuCore.IVR.SessionRegistry` to application.ex) |
| G15 — ITS naming conflict | Fixed in Step 0 (IVR renamed; new `VmuCore.ITS` = Interchange Tracking) |
| G13 → ITS paper trail absent | `its_copy_requests` + ITS1/ITS2 batch provide full interchange tracking |
