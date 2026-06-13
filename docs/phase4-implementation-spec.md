# Phase 4 Implementation Spec — TRAMS Clearing + COL Collections

**Target:** Weeks 19–24  
**Outcome:** Mastercard IPM and Visa Base II clearing files are processed and matched to authorized transactions. Delinquent accounts are managed through collection queues to write-off.

---

## Task Overview

| # | Task | Module | Depends On |
|---|---|---|---|
| 21 | Mastercard IPM Broadway pipeline — binary file producer + parser | vMu_trams | T7 (LedgerEntries) |
| 22 | Visa Base II parser + Broadway pipeline | vMu_trams | T21 |
| 23 | Auth-to-clearing matching engine + GL extract file | vMu_trams | T21, T22 |
| 24 | COL collection queue engine + dunning letter generator | vMu_col | T10 (EOD) |
| 25 | Write-off processor + recovery tracker | vMu_col | T24 |

---

## Task 21 — Mastercard IPM Broadway Pipeline

IPM (Interchange Posting Message) is Mastercard's binary clearing file format. It is a fixed-width record structure, not CSV. Each file contains thousands of transaction records processed as a stream.

### IPM File Structure (Mastercard)
```
File header (1004-byte record)
  └── Batch header (1004-byte record)
        └── Transaction records (1004-byte records, ISO 8583-like bitmapped format)
              └── Batch trailer
File trailer
```

Key data elements in each IPM transaction record:
- **DE2** — PAN (Primary Account Number)
- **DE3** — Processing code (purchase, refund, cash, etc.)
- **DE4** — Transaction amount
- **DE5** — Settlement amount
- **DE7** — Transmission date and time
- **DE12** — Local transaction time
- **DE37** — Retrieval reference number
- **DE38** — Authorization code
- **DE41** — Card acceptor terminal ID
- **DE42** — Card acceptor ID (merchant ID)
- **DE49** — Transaction currency code
- **DE63** — Network data

### Migration: `trams_clearing_records`
```sql
CREATE TABLE trams_clearing_records (
    clearing_id         UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    network             VARCHAR(10) NOT NULL,   -- MASTERCARD, VISA
    file_name           VARCHAR(255) NOT NULL,
    record_sequence     INTEGER     NOT NULL,
    pan_token           VARCHAR(64) NOT NULL,
    account_id          UUID        REFERENCES cms_accounts(account_id),
    processing_code     VARCHAR(6)  NOT NULL,
    transaction_amount  DECIMAL(18,2) NOT NULL,
    settlement_amount   DECIMAL(18,2) NOT NULL,
    transaction_currency VARCHAR(3) NOT NULL,
    transmission_datetime TIMESTAMP NOT NULL,
    retrieval_reference VARCHAR(12),
    auth_code           VARCHAR(6),
    terminal_id         VARCHAR(8),
    merchant_id         VARCHAR(15),
    mcc                 VARCHAR(4),
    -- Matching state
    match_status        VARCHAR(20) NOT NULL DEFAULT 'UNMATCHED',  -- UNMATCHED, MATCHED, EXCEPTION
    matched_auth_id     UUID,                   -- reference to the original authorization
    -- GL state
    gl_posted           BOOLEAN     NOT NULL DEFAULT false,
    gl_post_date        DATE,
    -- Audit
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);
CREATE INDEX ON trams_clearing_records (pan_token, match_status);
CREATE INDEX ON trams_clearing_records (auth_code, match_status);
CREATE INDEX ON trams_clearing_records (retrieval_reference);
```

### Broadway Producer: `lib/vmu_core/trams/ipm_producer.ex`
```elixir
defmodule VmuCore.TRAMS.IpmProducer do
  use GenStage

  @moduledoc """
  Broadway custom producer for Mastercard IPM files.
  Reads binary IPM file from SFTP/S3, parses record by record,
  emits each transaction record as a Broadway message.
  """

  @record_length 1004   # IPM standard record length (bytes)

  def start_link(opts) do
    GenStage.start_link(__MODULE__, opts)
  end

  @impl GenStage
  def init(opts) do
    file_path = Keyword.fetch!(opts, :file_path)
    {:ok, data} = File.read(file_path)
    records = chunk_records(data)
    {:producer, %{records: records, demand: 0}}
  end

  @impl GenStage
  def handle_demand(demand, %{records: records} = state) when length(records) >= demand do
    {to_emit, remaining} = Enum.split(records, demand)
    messages = Enum.map(to_emit, &%Broadway.Message{data: &1, acknowledger: Broadway.NoopAcknowledger.init()})
    {:noreply, messages, %{state | records: remaining}}
  end

  def handle_demand(_demand, %{records: []} = state), do: {:noreply, [], state}

  defp chunk_records(binary) do
    # Skip file header (first 1004 bytes) and batch headers
    binary
    |> :binary.bin_to_list()
    |> Enum.chunk_every(@record_length)
    |> Enum.map(&:binary.list_to_bin/1)
    |> Enum.reject(&header_or_trailer?/1)
  end

  defp header_or_trailer?(record) do
    # Record type identifier in first 4 bytes
    type = binary_part(record, 0, 4)
    type in ["1014", "5014", "9014"]  # header/trailer MTIs
  end
end
```

### Broadway Pipeline: `lib/vmu_core/trams/ipm_pipeline.ex`
```elixir
defmodule VmuCore.TRAMS.IpmPipeline do
  use Broadway

  alias VmuCore.TRAMS.{IpmParser, ClearingRecord}
  alias VmuCore.Repo

  def start_link(file_path) do
    Broadway.start_link(__MODULE__,
      name: __MODULE__,
      producer: [
        module: {VmuCore.TRAMS.IpmProducer, [file_path: file_path]},
        concurrency: 1
      ],
      processors: [
        default: [concurrency: 10]   # Parse and insert concurrently
      ],
      batchers: [
        gl_poster: [concurrency: 2, batch_size: 100, batch_timeout: 1_000]
      ]
    )
  end

  @impl Broadway
  def handle_message(_processor, %Broadway.Message{data: raw_record} = message, _context) do
    case IpmParser.parse(raw_record) do
      {:ok, parsed} ->
        Repo.insert!(%ClearingRecord{
          network: "MASTERCARD",
          file_name: "current_ipm",
          pan_token:            hash_pan(parsed.pan),
          processing_code:      parsed.processing_code,
          transaction_amount:   parsed.amount,
          settlement_amount:    parsed.settlement_amount,
          transaction_currency: parsed.currency,
          transmission_datetime: parsed.transmission_datetime,
          retrieval_reference:  parsed.retrieval_reference,
          auth_code:            parsed.auth_code,
          terminal_id:          parsed.terminal_id,
          merchant_id:          parsed.merchant_id,
          mcc:                  parsed.mcc
        })
        Broadway.Message.put_batcher(message, :gl_poster)

      {:error, reason} ->
        Broadway.Message.failed(message, reason)
    end
  end

  @impl Broadway
  def handle_batch(:gl_poster, messages, _batch_info, _context) do
    # Trigger matching + GL posting for this batch
    Enum.each(messages, fn msg ->
      clearing_id = msg.data[:clearing_id]
      VmuCore.TRAMS.MatchingEngine.match_and_post(clearing_id)
    end)
    messages
  end

  defp hash_pan(pan), do: :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)
end
```

### IPM Parser: `lib/vmu_core/trams/ipm_parser.ex`
```elixir
defmodule VmuCore.TRAMS.IpmParser do
  @moduledoc """
  Parses a single IPM record (1004 bytes, bitmapped ISO 8583-like format).
  Data elements are in Mastercard's fixed positions within the record.
  """

  def parse(record) when byte_size(record) == 1004 do
    try do
      {:ok, %{
        mti:                  binary_part(record, 0, 4),
        bitmap:               binary_part(record, 4, 16),   # 128-bit bitmap
        pan:                  extract_de(record, 2),
        processing_code:      extract_de(record, 3),
        amount:               extract_amount(record, 4),
        settlement_amount:    extract_amount(record, 5),
        transmission_datetime: extract_datetime(record, 7),
        retrieval_reference:  extract_de(record, 37),
        auth_code:            extract_de(record, 38),
        terminal_id:          extract_de(record, 41),
        merchant_id:          extract_de(record, 42),
        mcc:                  extract_de(record, 18),
        currency:             extract_de(record, 49),
        settlement_currency:  extract_de(record, 50)
      }}
    rescue
      e -> {:error, {:parse_error, inspect(e)}}
    end
  end

  def parse(_), do: {:error, :invalid_record_length}

  # These offsets are illustrative — actual DE positions require the
  # Mastercard IPM File Format specification document
  defp extract_de(_record, _de_number), do: "PLACEHOLDER"
  defp extract_amount(_record, _de), do: Decimal.new("0")
  defp extract_datetime(_record, _de), do: DateTime.utc_now()
end
```

> **Note:** The exact byte offsets for each DE require the Mastercard IPM File Format document (IPM Technical Manual). The structure above is correct — the `extract_de/2` implementations must be completed against that spec.

---

## Task 22 — Visa Base II Parser

Visa Base II is a different format from Mastercard IPM — it is record-based but uses a different fixed-width structure with Visa-specific data elements.

### Key differences from IPM:
- Record length: 150 bytes per transaction record (Base II) vs 1004 bytes (IPM)
- Field positions follow Visa's BASE II format specification
- Uses VSS (Visa Settlement Service) for actual settlement
- Record types: 01 (header), 05 (transaction), 90 (trailer)

```elixir
defmodule VmuCore.TRAMS.VisaBaseIIParser do
  @record_length 150
  @transaction_record_type "05"

  def parse_file(file_path) do
    file_path
    |> File.stream!([], @record_length)
    |> Stream.filter(&transaction_record?/1)
    |> Stream.map(&parse_record/1)
    |> Stream.filter(&match?({:ok, _}, &1))
    |> Stream.map(fn {:ok, record} -> record end)
  end

  defp transaction_record?(record), do: binary_part(record, 0, 2) == @transaction_record_type

  defp parse_record(record) do
    try do
      {:ok, %{
        record_type:          binary_part(record, 0, 2),
        pan:                  String.trim(binary_part(record, 2, 19)),
        processing_code:      binary_part(record, 21, 6),
        amount:               parse_amount(binary_part(record, 27, 12)),
        settlement_amount:    parse_amount(binary_part(record, 39, 12)),
        transaction_date:     parse_date(binary_part(record, 51, 4)),
        retrieval_reference:  binary_part(record, 55, 12),
        auth_code:            binary_part(record, 67, 6),
        terminal_id:          binary_part(record, 73, 8),
        merchant_id:          binary_part(record, 81, 15),
        mcc:                  binary_part(record, 96, 4),
        currency:             binary_part(record, 100, 3)
      }}
    rescue
      e -> {:error, {:parse_error, inspect(e)}}
    end
  end

  defp parse_amount(str), do: str |> String.trim() |> Decimal.new() |> Decimal.div(Decimal.new("100"))
  defp parse_date(mmdd), do: Date.new!(Date.utc_today().year, String.to_integer(binary_part(mmdd, 0, 2)), String.to_integer(binary_part(mmdd, 2, 2)))
end
```

---

## Task 23 — Auth-to-Clearing Matching Engine + GL Extract

After clearing records are parsed and stored, each must be matched to its original authorization. Unmatched records go to an exception queue.

```elixir
defmodule VmuCore.TRAMS.MatchingEngine do
  alias VmuCore.{Repo, TRAMS.ClearingRecord, CMS.InternalGlPoster}
  import Ecto.Query

  @doc "Match a clearing record to its authorization and post to GL."
  def match_and_post(clearing_id) do
    clearing = Repo.get!(ClearingRecord, clearing_id)

    case find_matching_auth(clearing) do
      {:ok, auth} ->
        Repo.transaction(fn ->
          # Mark clearing as matched
          Repo.update_all(
            from(c in ClearingRecord, where: c.clearing_id == ^clearing_id),
            set: [match_status: "MATCHED", matched_auth_id: auth.auth_id]
          )

          # Post to GL
          InternalGlPoster.post_purchase(
            clearing.account_id,
            clearing.settlement_amount,
            clearing.retrieval_reference,
            Date.utc_today()
          )

          # Update clearing record as GL-posted
          Repo.update_all(
            from(c in ClearingRecord, where: c.clearing_id == ^clearing_id),
            set: [gl_posted: true, gl_post_date: Date.utc_today()]
          )
        end)

      {:error, :no_match} ->
        Repo.update_all(
          from(c in ClearingRecord, where: c.clearing_id == ^clearing_id),
          set: [match_status: "EXCEPTION"]
        )
        {:error, :unmatched_clearing}
    end
  end

  # Match strategy: auth_code → retrieval_reference → amount + date window
  defp find_matching_auth(clearing) do
    query =
      from a in VmuCore.TRAMS.AuthRecord,
        where: a.pan_token == ^clearing.pan_token
          and a.auth_code == ^clearing.auth_code
          and a.match_status == "UNMATCHED",
        limit: 1

    case Repo.one(query) do
      nil  -> {:error, :no_match}
      auth -> {:ok, auth}
    end
  end
end
```

### GL Extract file generator (for core banking):
```elixir
defmodule VmuCore.TRAMS.GlExtractor do
  @doc "Generate a GL extract file for a given date — sent to core banking."
  def generate_daily_extract(extract_date) do
    import Ecto.Query

    entries = VmuCore.Repo.all(
      from e in VmuCore.CMS.LedgerEntry,
        where: e.posting_date == ^extract_date and e.gl_extracted == false,
        order_by: [e.account_id, e.inserted_at]
    )

    lines = Enum.map(entries, fn e ->
      "#{e.posting_date}|#{e.dr_account_code}|#{e.cr_account_code}|#{e.amount}|#{e.transaction_code}|#{e.source_reference}"
    end)

    file_content = ["DATE|DR_ACCT|CR_ACCT|AMOUNT|TXN_CODE|REFERENCE" | lines]
                   |> Enum.join("\n")

    file_path = "gl_extract_#{extract_date}.csv"
    File.write!(file_path, file_content)

    # Mark entries as extracted
    ids = Enum.map(entries, & &1.entry_id)
    VmuCore.Repo.update_all(
      from(e in VmuCore.CMS.LedgerEntry, where: e.entry_id in ^ids),
      set: [gl_extracted: true, gl_extracted_at: DateTime.utc_now()]
    )

    {:ok, file_path}
  end
end
```

---

## Task 24 — COL Collection Queue Engine + Dunning Letters

Collections is triggered by the EOD aging process (Task 10 Step 3). When an account reaches a DPD threshold, COL takes over with queues and automated correspondence.

### Migration: `col_collection_cases` + `col_dunning_letters`
```sql
CREATE TABLE col_collection_cases (
    case_id             UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          UUID        NOT NULL REFERENCES cms_accounts(account_id),
    dpd_bucket          SMALLINT    NOT NULL,           -- 30, 60, 90, 120
    outstanding_amount  DECIMAL(18,2) NOT NULL,
    minimum_due         DECIMAL(18,2) NOT NULL,
    status              VARCHAR(20) NOT NULL DEFAULT 'OPEN',
    assigned_agent      VARCHAR(50),                    -- collection agent or agency
    workout_plan_id     UUID,
    opened_at           DATE        NOT NULL DEFAULT CURRENT_DATE,
    closed_at           DATE,
    resolution          VARCHAR(30),                    -- PAID, WORKOUT, WRITTEN_OFF, AGENCY
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);

CREATE TABLE col_dunning_letters (
    letter_id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    case_id             UUID        NOT NULL REFERENCES col_collection_cases(case_id),
    account_id          UUID        NOT NULL REFERENCES cms_accounts(account_id),
    letter_type         VARCHAR(30) NOT NULL,           -- FIRST_NOTICE, SECOND_NOTICE, FINAL_NOTICE, LEGAL
    dpd_at_send         SMALLINT    NOT NULL,
    amount_due          DECIMAL(18,2) NOT NULL,
    due_date            DATE        NOT NULL,
    delivery_channel    VARCHAR(10) NOT NULL DEFAULT 'EMAIL',
    sent_at             TIMESTAMP,
    opened_at           TIMESTAMP,
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW()
);
```

### Module: `lib/vmu_core/col/collection_engine.ex`
```elixir
defmodule VmuCore.COL.CollectionEngine do
  @moduledoc """
  Manages delinquent account queues and automated dunning correspondence.
  Called by the EOD aging step when an account's DPD bucket advances.
  """

  alias VmuCore.{Repo, CMS.Account, COL.CollectionCase, COL.DunningLetter}
  import Ecto.Query

  @dunning_schedule %{
    30  => {:first_notice,  "FIRST_NOTICE",  7},   # {dpd, letter_type, due_days}
    60  => {:second_notice, "SECOND_NOTICE", 14},
    90  => {:final_notice,  "FINAL_NOTICE",  7},
    120 => {:legal,         "LEGAL",         3}
  }

  @doc "Open or escalate a collection case when DPD advances."
  def handle_dpd_advance(account_id, new_dpd, outstanding_amount, minimum_due) do
    case Repo.get_by(CollectionCase, account_id: account_id, status: "OPEN") do
      nil ->
        open_new_case(account_id, new_dpd, outstanding_amount, minimum_due)

      existing ->
        escalate_case(existing, new_dpd, outstanding_amount)
    end
  end

  @doc "Close a collection case when the account pays in full."
  def close_on_payment(account_id) do
    Repo.update_all(
      from(c in CollectionCase,
        where: c.account_id == ^account_id and c.status == "OPEN"),
      set: [status: "CLOSED", resolution: "PAID", closed_at: Date.utc_today()]
    )
  end

  # ---------------------------------------------------------------------------

  defp open_new_case(account_id, dpd, outstanding, minimum) do
    case_record = Repo.insert!(%CollectionCase{
      account_id: account_id, dpd_bucket: dpd,
      outstanding_amount: outstanding, minimum_due: minimum
    })
    send_dunning_letter(case_record, dpd, outstanding, minimum)
    {:ok, case_record}
  end

  defp escalate_case(case_record, new_dpd, outstanding) do
    Repo.update!(CollectionCase.changeset(case_record, %{
      dpd_bucket: new_dpd, outstanding_amount: outstanding
    }))
    send_dunning_letter(case_record, new_dpd, outstanding, case_record.minimum_due)
  end

  defp send_dunning_letter(case_record, dpd, outstanding, _minimum) do
    {_atom, letter_type, due_days} = Map.fetch!(@dunning_schedule, dpd)
    due_date = Date.add(Date.utc_today(), due_days)

    letter = Repo.insert!(%DunningLetter{
      case_id: case_record.case_id, account_id: case_record.account_id,
      letter_type: letter_type, dpd_at_send: dpd,
      amount_due: outstanding, due_date: due_date
    })

    # Enqueue async delivery job (email/SMS)
    %{"letter_id" => letter.letter_id}
    |> VmuCore.COL.DunningDeliveryJob.new()
    |> Oban.insert!()
  end
end
```

---

## Task 25 — Write-Off Processor + Recovery Tracker

When an account reaches 120+ DPD and no workout plan is active, it is written off. Post write-off, any partial repayments are tracked as recoveries.

```elixir
defmodule VmuCore.COL.WriteOffProcessor do
  alias VmuCore.{Repo, CMS.Account, CMS.InternalGlPoster, COL.CollectionCase}
  import Ecto.Query

  @doc "Write off an account balance. Idempotent."
  def write_off(account_id, reason \\ "120_DPD") do
    account = Repo.get!(Account, account_id)
    bucket  = Repo.get_by!(VmuCore.CMS.BalanceBucket, account_id: account_id)

    total_balance = VmuCore.CMS.Account.total_balance(account, bucket)

    if Decimal.compare(total_balance, Decimal.new("0")) == :gt do
      Repo.transaction(fn ->
        # GL: move balance from receivable to written-off
        InternalGlPoster.post(%{
          account_id:       account_id,
          transaction_code: "WOFF",
          dr_account_code:  "61000",   -- Bad Debt Expense
          cr_account_code:  "11000",   -- Cardholder Receivable
          amount:           total_balance,
          source_type:      "COLLECTION",
          source_reference: "WOFF:#{account_id}",
          posting_date:     Date.utc_today(),
          value_date:       Date.utc_today(),
          bucket_affected:  "RETAIL",
          idempotency_key:  "WOFF:#{account_id}:#{Date.utc_today()}"
        })

        # Close the account
        Repo.update_all(
          from(a in Account, where: a.account_id == ^account_id),
          set: [account_status: "WRITTEN_OFF", open_to_buy: Decimal.new("0")]
        )

        # Close collection case
        Repo.update_all(
          from(c in CollectionCase, where: c.account_id == ^account_id and c.status == "OPEN"),
          set: [status: "CLOSED", resolution: "WRITTEN_OFF", closed_at: Date.utc_today()]
        )

        # Notify AccountStateCoordinator to stop accepting auths
        VmuCore.CMS.AccountStateCoordinator.refresh(account_id)
      end)
    else
      {:error, :zero_balance}
    end
  end
end

defmodule VmuCore.COL.RecoveryTracker do
  @doc "Post a recovery payment for a written-off account."
  def post_recovery(account_id, amount, reference, payment_date) do
    VmuCore.CMS.InternalGlPoster.post(%{
      account_id:       account_id,
      transaction_code: "RCVR",
      dr_account_code:  "21000",   -- Cash received
      cr_account_code:  "61000",   -- Reduce bad debt expense
      amount:           amount,
      source_type:      "COLLECTION",
      source_reference: reference,
      posting_date:     payment_date,
      value_date:       payment_date,
      bucket_affected:  "RETAIL",
      idempotency_key:  "RCVR:#{reference}:#{account_id}"
    })
  end
end
```

---

## Phase 4 Done Criteria

- [ ] `IpmProducer` reads a real IPM binary file and chunks it into 1004-byte records correctly
- [ ] `IpmPipeline` processes 1000 test records concurrently without data loss; all inserted into `trams_clearing_records`
- [ ] `VisaBaseIIParser.parse_file/1` streams a Base II file and returns parsed maps for transaction records
- [ ] `MatchingEngine.match_and_post/1` matches a clearing record to a seeded auth record and posts a GL entry
- [ ] Unmatched clearing records get `match_status = "EXCEPTION"` (not left as UNMATCHED)
- [ ] `GlExtractor.generate_daily_extract/1` produces a valid pipe-delimited CSV for all unextracted entries
- [ ] `CollectionEngine.handle_dpd_advance/4` opens a new case and inserts a dunning letter record at 30 DPD
- [ ] At 60/90/120 DPD, escalation updates the existing case (not creates a new one)
- [ ] `CollectionEngine.close_on_payment/1` closes the open case with resolution "PAID"
- [ ] `WriteOffProcessor.write_off/2` posts a WOFF ledger entry, sets account_status to WRITTEN_OFF, and closes collection case
- [ ] `WriteOffProcessor.write_off/2` is idempotent — calling twice on same account returns `{:error, :zero_balance}` second time
- [ ] `RecoveryTracker.post_recovery/4` posts a RCVR ledger entry with correct GL accounts
