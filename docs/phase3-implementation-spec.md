# Phase 3 Implementation Spec — ITS Telephony + DPS Disputes

**Target:** Weeks 13–18  
**Outcome:** Cardholders can self-serve via IVR (balance, PIN, activate, block). Disputes are filed with Visa/MC with hard deadline enforcement via Oban.

---

## Task Overview

| # | Task | Module | Depends On |
|---|---|---|---|
| 16 | `IvrSession` GenServer — session state machine | vMu_its | T4 (AccountStateCoordinator) |
| 17 | IVR PIN flows — set/change/verify/retrieve via HSM | vMu_its | T14 (PinIssuanceService), T16 |
| 18 | OTP engine — HOTP/TOTP generation + validation | vMu_its | — |
| 19 | Dispute state machine + Oban deadline scheduler | vMu_dps | T7 (LedgerEntries) |
| 20 | Provisional credit posting — DPS→CMS GL | vMu_dps | T19, T7 |

---

## Task 16 — IVR Session State Machine

ITS manages a per-call GenServer session. Each IVR call authenticates the cardholder, then drives a menu-driven state machine.

### Session States
```
:unauthenticated → :authenticated → :menu → :action_in_progress → :closed
```

### Migration: `its_ivr_sessions` (audit log)
```sql
CREATE TABLE its_ivr_sessions (
    session_id      UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id      UUID        REFERENCES cms_accounts(account_id),
    call_ref        VARCHAR(64) NOT NULL UNIQUE,   -- IVR platform call ID
    ani             VARCHAR(20),                    -- Automatic Number Identification (caller ID)
    auth_method     VARCHAR(20),                    -- CARD_PAN, MOBILE_OTP
    auth_status     VARCHAR(20) NOT NULL DEFAULT 'PENDING',
    actions_taken   JSONB       NOT NULL DEFAULT '[]',
    started_at      TIMESTAMP   NOT NULL DEFAULT NOW(),
    ended_at        TIMESTAMP,
    exit_reason     VARCHAR(50)
);
```

### Module: `lib/vmu_core/its/ivr_session.ex`
```elixir
defmodule VmuCore.ITS.IvrSession do
  use GenServer, restart: :temporary
  require Logger

  # IVR sessions auto-terminate after 10 minutes of inactivity
  @idle_timeout_ms 10 * 60 * 1_000

  defstruct [
    :session_id, :call_ref, :account_id,
    state: :unauthenticated,
    auth_attempts: 0,
    actions_taken: []
  ]

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  def start(call_ref, ani) do
    GenServer.start(__MODULE__, %{call_ref: call_ref, ani: ani})
  end

  def authenticate(pid, account_id, credential_type, credential_value) do
    GenServer.call(pid, {:authenticate, account_id, credential_type, credential_value}, 10_000)
  end

  def execute_action(pid, action, params) do
    GenServer.call(pid, {:execute, action, params}, 15_000)
  end

  def end_call(pid, reason \\ :normal) do
    GenServer.cast(pid, {:end_call, reason})
  end

  # ---------------------------------------------------------------------------
  # GenServer callbacks
  # ---------------------------------------------------------------------------

  @impl true
  def init(%{call_ref: call_ref, ani: ani}) do
    session_id = Ecto.UUID.generate()
    VmuCore.Repo.insert!(%VmuCore.ITS.IvrSessionRecord{
      session_id: session_id, call_ref: call_ref, ani: ani
    })
    {:ok, %__MODULE__{session_id: session_id, call_ref: call_ref}, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:authenticate, account_id, cred_type, cred_value}, _from, %{state: :unauthenticated} = s) do
    case verify_credential(account_id, cred_type, cred_value) do
      :ok ->
        new_state = %{s | state: :authenticated, account_id: account_id, auth_attempts: 0}
        log_action(new_state, "AUTH_SUCCESS", %{method: cred_type})
        {:reply, {:ok, :authenticated}, new_state, @idle_timeout_ms}

      {:error, reason} ->
        attempts = s.auth_attempts + 1
        if attempts >= 3 do
          {:reply, {:error, :max_attempts}, %{s | state: :closed}, 0}
        else
          {:reply, {:error, reason}, %{s | auth_attempts: attempts}, @idle_timeout_ms}
        end
    end
  end

  @impl true
  def handle_call({:execute, action, params}, _from, %{state: :authenticated} = s) do
    result = dispatch_action(action, s.account_id, params)
    log_action(s, action, params)
    {:reply, result, %{s | state: :authenticated}, @idle_timeout_ms}
  end

  @impl true
  def handle_call({:execute, _action, _params}, _from, state) do
    {:reply, {:error, :not_authenticated}, state, @idle_timeout_ms}
  end

  @impl true
  def handle_cast({:end_call, reason}, state) do
    persist_session_end(state, reason)
    {:stop, :normal, state}
  end

  @impl true
  def handle_info(:timeout, state) do
    persist_session_end(state, :timeout)
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Action dispatcher — menu items
  # ---------------------------------------------------------------------------

  defp dispatch_action(:balance_inquiry, account_id, _params) do
    case VmuCore.CMS.AccountStateCoordinator.authorize(account_id, Decimal.new("0"), channel: :ivr) do
      # Just load state without actually authorizing — use a 0-amount check
      _ -> VmuCore.ITS.Actions.BalanceInquiry.execute(account_id)
    end
  end

  defp dispatch_action(:pin_change, account_id, %{new_pin_block: pin_block}) do
    VmuCore.ITS.Actions.PinChange.execute(account_id, pin_block)
  end

  defp dispatch_action(:card_block, account_id, %{reason: reason}) do
    VmuCore.ITS.Actions.CardBlock.execute(account_id, reason)
  end

  defp dispatch_action(:activation, account_id, %{activation_code: code, stock_id: stock_id}) do
    VmuCore.CMS.CardActivationService.activate(account_id, code, stock_id)
  end

  defp dispatch_action(:transaction_history, account_id, %{count: count}) do
    VmuCore.ITS.Actions.TransactionHistory.execute(account_id, count)
  end

  defp dispatch_action(unknown, _account_id, _params) do
    {:error, {:unknown_action, unknown}}
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp verify_credential(account_id, :card_pan, pan) do
    # Verify last 4 digits match — IVR uses last-4 as a simple auth factor
    case VmuCore.Repo.get_by(VmuCore.CMS.Account, account_id: account_id) do
      %{last_four: last_four} when last_four == String.slice(pan, -4, 4) -> :ok
      _ -> {:error, :invalid_credential}
    end
  end

  defp verify_credential(account_id, :otp, otp_value) do
    VmuCore.ITS.OtpEngine.verify(account_id, otp_value)
  end

  defp log_action(state, action, params) do
    entry = %{action: action, params: params, timestamp: DateTime.utc_now()}
    VmuCore.Repo.update_all(
      from(s in VmuCore.ITS.IvrSessionRecord, where: s.session_id == ^state.session_id),
      push: [actions_taken: entry]
    )
  end

  defp persist_session_end(state, reason) do
    VmuCore.Repo.update_all(
      from(s in VmuCore.ITS.IvrSessionRecord, where: s.session_id == ^state.session_id),
      set: [ended_at: DateTime.utc_now(), exit_reason: "#{reason}"]
    )
  end
end
```

---

## Task 17 — IVR PIN Flows

PIN operations via IVR reuse `PinIssuanceService` from Task 14. The IVR session wraps them with audit logging.

```elixir
defmodule VmuCore.ITS.Actions.PinChange do
  alias VmuCore.CTA.PinIssuanceService

  @doc "Change PIN via IVR — called from IvrSession dispatcher."
  def execute(account_id, new_pin_block) do
    account = VmuCore.Repo.get!(VmuCore.CMS.Account, account_id)
    # Reconstruct PAN from token for HSM — in practice, retrieve from secure vault
    pan = reconstruct_pan(account)
    PinIssuanceService.change_pin(pan, account_id, new_pin_block)
  end

  defp reconstruct_pan(_account) do
    # In production: retrieve PAN from PAN vault (separate encrypted store)
    # Never stored in cms_accounts directly
    raise "PAN vault integration required — connect to secure PAN storage"
  end
end

defmodule VmuCore.ITS.Actions.PinVerify do
  alias VmuCore.CTA.PinIssuanceService

  def execute(account_id, presented_pin_block) do
    account = VmuCore.Repo.get!(VmuCore.CMS.Account, account_id)
    pan     = reconstruct_pan(account)
    PinIssuanceService.verify_pin(pan, account_id, presented_pin_block)
  end

  defp reconstruct_pan(_account), do: raise("PAN vault integration required")
end
```

---

## Task 18 — OTP Engine (HOTP/TOTP)

Used for: cardholder portal 2FA, IVR authentication fallback, card-not-present transaction OTP.

```elixir
defmodule VmuCore.ITS.OtpEngine do
  @moduledoc """
  HOTP (RFC 4226) OTP generation and verification.
  OTPs are 6-digit, valid for 5 minutes, single-use.
  Delivery channels: SMS, email. Delivery is delegated to notification adapter.
  """

  @otp_validity_seconds 300   # 5 minutes
  @otp_digits 6

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc "Generate and store a new OTP for the account. Returns the OTP value for delivery."
  def generate(account_id, channel \\ :sms) do
    otp = :crypto.strong_rand_bytes(4)
           |> :binary.decode_unsigned()
           |> rem(trunc(:math.pow(10, @otp_digits)))
           |> Integer.to_string()
           |> String.pad_leading(@otp_digits, "0")

    expires_at = DateTime.add(DateTime.utc_now(), @otp_validity_seconds, :second)

    VmuCore.Repo.insert!(%VmuCore.ITS.OtpRecord{
      account_id:  account_id,
      otp_hash:    hash_otp(otp),
      channel:     channel,
      expires_at:  expires_at,
      used:        false
    })

    {:ok, otp}
  end

  @doc "Verify an OTP. Returns :ok or {:error, reason}. Marks OTP as used on success."
  def verify(account_id, presented_otp) do
    import Ecto.Query

    case VmuCore.Repo.one(
      from o in VmuCore.ITS.OtpRecord,
        where: o.account_id == ^account_id
          and o.used == false
          and o.expires_at > ^DateTime.utc_now(),
        order_by: [desc: o.inserted_at],
        limit: 1
    ) do
      nil ->
        {:error, :no_valid_otp}

      record ->
        if hash_otp(presented_otp) == record.otp_hash do
          VmuCore.Repo.update_all(
            from(o in VmuCore.ITS.OtpRecord, where: o.id == ^record.id),
            set: [used: true, used_at: DateTime.utc_now()]
          )
          :ok
        else
          {:error, :invalid_otp}
        end
    end
  end

  defp hash_otp(otp), do: :crypto.hash(:sha256, otp) |> Base.encode16(case: :lower)
end
```

### Migration: `its_otp_records`
```sql
CREATE TABLE its_otp_records (
    id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id  UUID        NOT NULL REFERENCES cms_accounts(account_id),
    otp_hash    VARCHAR(64) NOT NULL,
    channel     VARCHAR(10) NOT NULL DEFAULT 'sms',
    expires_at  TIMESTAMP   NOT NULL,
    used        BOOLEAN     NOT NULL DEFAULT false,
    used_at     TIMESTAMP,
    inserted_at TIMESTAMP   NOT NULL DEFAULT NOW()
);
CREATE INDEX ON its_otp_records (account_id, expires_at, used);
```

---

## Task 19 — Dispute State Machine + Deadline Scheduler

Dispute processing is the most time-sensitive part of card operations. Visa and Mastercard impose hard deadlines at each stage. A missed deadline forfeits the case — the issuer absorbs the loss automatically.

### Dispute Stages and Deadlines (Visa / Mastercard)

| Stage | Deadline (Visa) | Deadline (MC) |
|---|---|---|
| File retrieval request | 30 days from transaction | 45 days from transaction |
| File chargeback | 120 days from transaction | 120 days from transaction |
| Respond to representment | 30 days from representment | 45 days from representment |
| File pre-arbitration | 30 days after representment response | N/A (different flow) |
| Respond to pre-arbitration | 10 days | N/A |
| File arbitration | 10 days | 45 days from chargeback |

### Migration: `dps_disputes`
```sql
CREATE TABLE dps_disputes (
    dispute_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          UUID        NOT NULL REFERENCES cms_accounts(account_id),
    transaction_date    DATE        NOT NULL,
    transaction_amount  DECIMAL(18,2) NOT NULL,
    transaction_ref     VARCHAR(64),             -- original STAN or clearing reference
    merchant_name       VARCHAR(100),
    mcc                 VARCHAR(4),
    network             VARCHAR(10) NOT NULL,    -- VISA, MASTERCARD
    reason_code         VARCHAR(10) NOT NULL,    -- Visa/MC dispute reason code
    cardholder_amount   DECIMAL(18,2) NOT NULL,  -- amount disputed by cardholder
    -- State
    status              VARCHAR(30) NOT NULL DEFAULT 'FILED',
    -- Deadlines (computed at filing; enforced by Oban)
    retrieval_deadline  DATE,
    chargeback_deadline DATE        NOT NULL,
    response_deadline   DATE,
    -- Financial tracking
    provisional_credit  DECIMAL(18,2) NOT NULL DEFAULT 0,
    final_resolution    VARCHAR(20),             -- WON, LOST, PARTIAL
    recovered_amount    DECIMAL(18,2) NOT NULL DEFAULT 0,
    -- Audit
    filed_at            TIMESTAMP   NOT NULL DEFAULT NOW(),
    closed_at           TIMESTAMP,
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMP   NOT NULL DEFAULT NOW()
);
-- Valid statuses: FILED, RETRIEVAL_REQUESTED, CHARGEBACK_FILED, REPRESENTED,
--                PRE_ARBITRATION, ARBITRATION, WON, LOST, WITHDRAWN
CREATE INDEX ON dps_disputes (account_id, status);
CREATE INDEX ON dps_disputes (chargeback_deadline) WHERE status NOT IN ('WON', 'LOST', 'WITHDRAWN');
```

### Module: `lib/vmu_core/dps/dispute.ex`
```elixir
defmodule VmuCore.DPS.Dispute do
  @moduledoc """
  Dispute state machine with VisionPlus/network lifecycle.

  State transitions:
    FILED → RETRIEVAL_REQUESTED → CHARGEBACK_FILED → REPRESENTED
          → PRE_ARBITRATION → ARBITRATION → WON | LOST | WITHDRAWN
  """

  alias VmuCore.{Repo, DPS.DisputeRecord, DPS.DeadlineScheduler}

  @valid_transitions %{
    "FILED"                 => ~w[RETRIEVAL_REQUESTED CHARGEBACK_FILED WITHDRAWN],
    "RETRIEVAL_REQUESTED"   => ~w[CHARGEBACK_FILED WITHDRAWN],
    "CHARGEBACK_FILED"      => ~w[REPRESENTED WON],
    "REPRESENTED"           => ~w[PRE_ARBITRATION LOST WON],
    "PRE_ARBITRATION"       => ~w[ARBITRATION WON],
    "ARBITRATION"           => ~w[WON LOST]
  }

  @doc "File a new dispute."
  def file(attrs) do
    chargeback_deadline = Date.add(attrs.transaction_date, 120)

    Repo.transaction(fn ->
      dispute = Repo.insert!(%DisputeRecord{
        Map.merge(attrs, %{
          status: "FILED",
          chargeback_deadline: chargeback_deadline
        })
      })

      # Issue provisional credit immediately on filing
      VmuCore.DPS.ProvisionalCredit.issue(dispute)

      # Schedule deadline enforcement jobs
      DeadlineScheduler.schedule_all(dispute)

      dispute
    end)
  end

  @doc "Transition a dispute to a new status."
  def transition(dispute_id, new_status, attrs \\ %{}) do
    dispute = Repo.get!(DisputeRecord, dispute_id)
    allowed = Map.get(@valid_transitions, dispute.status, [])

    if new_status in allowed do
      dispute
      |> DisputeRecord.changeset(Map.merge(attrs, %{status: new_status, updated_at: DateTime.utc_now()}))
      |> Repo.update()
    else
      {:error, {:invalid_transition, dispute.status, new_status}}
    end
  end

  @doc "Check for expired deadlines — called by Oban job."
  def check_deadline(dispute_id) do
    dispute = Repo.get!(DisputeRecord, dispute_id)
    today   = Date.utc_today()

    cond do
      dispute.status in ["WON", "LOST", "WITHDRAWN"] ->
        :already_closed

      Date.compare(today, dispute.chargeback_deadline) == :gt and
      dispute.status == "FILED" ->
        # Missed chargeback deadline — automatically lose
        transition(dispute_id, "LOST", %{final_resolution: "DEADLINE_EXPIRED", closed_at: DateTime.utc_now()})
        VmuCore.DPS.ProvisionalCredit.reverse(dispute)

      true ->
        :ok
    end
  end
end
```

### Module: `lib/vmu_core/dps/deadline_scheduler.ex`
```elixir
defmodule VmuCore.DPS.DeadlineScheduler do
  @moduledoc """
  Schedules Oban jobs that enforce Visa/MC dispute deadlines.
  Each job runs 24 hours before the deadline and again on the deadline day.
  """

  def schedule_all(dispute) do
    schedule_deadline(dispute.dispute_id, dispute.chargeback_deadline, "chargeback")

    if dispute.retrieval_deadline do
      schedule_deadline(dispute.dispute_id, dispute.retrieval_deadline, "retrieval")
    end
  end

  defp schedule_deadline(dispute_id, deadline_date, deadline_type) do
    # Warning: 24 hours before
    warning_at = deadline_date |> Date.add(-1) |> DateTime.new!(~T[09:00:00], "UTC")
    # Hard: on the deadline day at 00:01
    hard_at    = deadline_date |> DateTime.new!(~T[00:01:00], "UTC")

    %{"dispute_id" => dispute_id, "deadline_type" => deadline_type, "severity" => "warning"}
    |> VmuCore.DPS.DeadlineJob.new(scheduled_at: warning_at)
    |> Oban.insert!()

    %{"dispute_id" => dispute_id, "deadline_type" => deadline_type, "severity" => "hard"}
    |> VmuCore.DPS.DeadlineJob.new(scheduled_at: hard_at)
    |> Oban.insert!()
  end
end

defmodule VmuCore.DPS.DeadlineJob do
  use Oban.Worker, queue: :disputes, max_attempts: 5

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"dispute_id" => id, "severity" => "hard"}}) do
    VmuCore.DPS.Dispute.check_deadline(id)
  end

  def perform(%Oban.Job{args: %{"dispute_id" => id, "severity" => "warning"}}) do
    # Alert operations team — dispute approaching deadline
    VmuCore.Notifications.alert_ops("Dispute #{id} deadline approaching")
    :ok
  end
end
```

---

## Task 20 — Provisional Credit Posting

When a dispute is filed, the cardholder receives a provisional (temporary) credit. If the dispute is won, the credit becomes permanent. If lost, it is reversed.

```elixir
defmodule VmuCore.DPS.ProvisionalCredit do
  alias VmuCore.CMS.InternalGlPoster

  @doc "Issue provisional credit on dispute filing."
  def issue(dispute) do
    InternalGlPoster.post(%{
      account_id:       dispute.account_id,
      transaction_code: "PROV_CR",
      dr_account_code:  "21000",    -- Cards Payable (provisional)
      cr_account_code:  "11000",    -- Cardholder Receivable (reduces balance)
      amount:           dispute.cardholder_amount,
      source_type:      "DISPUTE",
      source_reference: dispute.dispute_id,
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today(),
      bucket_affected:  "DISPUTED",
      idempotency_key:  "PROV_CR:#{dispute.dispute_id}"
    })

    # Update balance bucket: move from retail to disputed
    VmuCore.Repo.update_all(
      from(b in VmuCore.CMS.BalanceBucket, where: b.account_id == ^dispute.account_id),
      inc: [
        retail_balance:  -dispute.cardholder_amount,
        disputed_amount: +dispute.cardholder_amount
      ]
    )

    # Restore OTB immediately (provisional credit restores spending power)
    VmuCore.CMS.AccountStateCoordinator.refresh(dispute.account_id)
  end

  @doc "Make provisional credit permanent (dispute WON)."
  def make_permanent(dispute) do
    InternalGlPoster.post(%{
      account_id:       dispute.account_id,
      transaction_code: "PERM_CR",
      dr_account_code:  "41000",    -- Write to income (chargeback recovery)
      cr_account_code:  "21000",    -- Clear the provisional liability
      amount:           dispute.recovered_amount,
      source_type:      "DISPUTE",
      source_reference: "WIN:#{dispute.dispute_id}",
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today(),
      bucket_affected:  "DISPUTED",
      idempotency_key:  "PERM_CR:#{dispute.dispute_id}"
    })

    VmuCore.Repo.update_all(
      from(b in VmuCore.CMS.BalanceBucket, where: b.account_id == ^dispute.account_id),
      inc: [disputed_amount: -dispute.recovered_amount]
    )
  end

  @doc "Reverse provisional credit (dispute LOST)."
  def reverse(dispute) do
    InternalGlPoster.post(%{
      account_id:       dispute.account_id,
      transaction_code: "PROV_REV",
      dr_account_code:  "11000",    -- Restore the balance
      cr_account_code:  "21000",
      amount:           dispute.provisional_credit,
      source_type:      "DISPUTE",
      source_reference: "LOSS:#{dispute.dispute_id}",
      posting_date:     Date.utc_today(),
      value_date:       Date.utc_today(),
      bucket_affected:  "DISPUTED",
      idempotency_key:  "PROV_REV:#{dispute.dispute_id}"
    })

    VmuCore.Repo.update_all(
      from(b in VmuCore.CMS.BalanceBucket, where: b.account_id == ^dispute.account_id),
      inc: [
        retail_balance:  +dispute.provisional_credit,
        disputed_amount: -dispute.provisional_credit
      ]
    )
    VmuCore.CMS.AccountStateCoordinator.refresh(dispute.account_id)
  end
end
```

---

## Phase 3 Done Criteria

- [ ] `IvrSession.start/2` creates a DB session record; `authenticate/4` succeeds with correct last-4 and fails after 3 wrong attempts
- [ ] `IvrSession.execute_action/3` returns error when called before authentication
- [ ] IVR PIN change calls `PinIssuanceService.change_pin/3`; new PIN verifies successfully
- [ ] `OtpEngine.generate/2` stores a hashed OTP; `verify/2` succeeds once and fails on reuse or expiry
- [ ] `Dispute.file/1` creates a dispute record with correct chargeback deadline (transaction_date + 120 days)
- [ ] `DeadlineScheduler.schedule_all/1` inserts 2 Oban jobs (warning + hard) in the disputes queue
- [ ] `DeadlineJob` running on deadline date transitions FILED dispute to LOST
- [ ] `ProvisionalCredit.issue/1` posts a PROV_CR ledger entry and moves amount from retail to disputed bucket
- [ ] `ProvisionalCredit.reverse/1` restores retail balance and refreshes AccountStateCoordinator
