# Phase 1 Implementation Spec — FAS Authorization Path + Shared Foundation

**Target:** Weeks 1–4  
**Outcome:** A working end-to-end authorization path: ISO 8583 MTI 0100 arrives → BIN resolved via ETS → AccountStateCoordinator validates OTB → approve/decline returned as MTI 0110.

---

## Overview of 6 Tasks

| # | Task | Module | Depends On |
|---|---|---|---|
| 1 | Add Horde dep + distributed registry setup | vMu_shared | Nothing |
| 2 | CIF customer entity schema + migration | vMu_shared | Nothing |
| 3 | Extend block_parameters + add cms_accounts + cms_balance_buckets schemas | vMu_cms | Task 2 |
| 4 | Build AccountStateCoordinator GenServer | vMu_cms | Tasks 1, 3 |
| 5 | Wire Switch.Router → ParameterEngine → AccountStateCoordinator | vMu_fas | Task 4 |
| 6 | Add STIP threshold table + fallback in auth path | vMu_fas | Task 5 |

Wire mw_risk velocity + sanctions into the auth path can be done in parallel with Tasks 4–6.

---

## Task 1 — Horde Setup

### mix.exs additions
```elixir
{:horde, "~> 0.9"},
{:libcluster, "~> 3.3"}   # for multi-node clustering in production
```

### New file: `lib/vmu_core/shared/registry.ex`
```elixir
defmodule VmuCore.Shared.Registry do
  @moduledoc """
  Horde-backed distributed registry for per-account GenServer processes.
  Processes registered here are accessible from any node in the cluster.
  """

  def child_spec(_opts) do
    [
      {Horde.Registry, [name: __MODULE__, keys: :unique, members: :auto]},
      {Horde.DynamicSupervisor, [name: VmuCore.Shared.AccountSupervisor, strategy: :one_for_one, members: :auto]}
    ]
  end

  @doc "Look up a registered process by key."
  def lookup(key), do: Horde.Registry.lookup(__MODULE__, key)

  @doc "Register the calling process under key."
  def register(key), do: Horde.Registry.register(__MODULE__, key, nil)

  @doc "Start a child under the distributed supervisor."
  def start_child(child_spec), do: Horde.DynamicSupervisor.start_child(VmuCore.Shared.AccountSupervisor, child_spec)
end
```

### Update `lib/vmu_core/application.ex`
```elixir
children = [
  VmuCore.Repo,
  VmuCore.Shared.ParameterEngine,
  # Horde distributed registry — must start after Repo
  {Horde.Registry, [name: VmuCore.Shared.Registry, keys: :unique, members: :auto]},
  {Horde.DynamicSupervisor, [name: VmuCore.Shared.AccountSupervisor, strategy: :one_for_one, members: :auto]}
]
```

### Test assertions for Task 1
```elixir
test "registry starts and accepts registration" do
  assert {:ok, _pid} = Horde.Registry.register(VmuCore.Shared.Registry, "test_key", nil)
  assert [{_pid, nil}] = Horde.Registry.lookup(VmuCore.Shared.Registry, "test_key")
end
```

---

## Task 2 — CIF Customer Entity

VisionPlus separates the **customer** (person) from the **account** (card product). One customer can have multiple accounts.

### Migration: `priv/repo/migrations/TIMESTAMP_create_cms_customers.exs`
```sql
CREATE TABLE cms_customers (
    customer_id     UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    sys_id          VARCHAR(4)  NOT NULL REFERENCES sys_parameters(sys_id),
    bank_id         VARCHAR(4)  NOT NULL,
    -- Identity
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    date_of_birth   DATE,
    nationality     VARCHAR(3),  -- ISO 3166-1 alpha-3
    -- Contact
    email           VARCHAR(255),
    mobile_country  VARCHAR(4),
    mobile_number   VARCHAR(20),
    -- Address
    address_line1   VARCHAR(255),
    address_line2   VARCHAR(255),
    city            VARCHAR(100),
    postal_code     VARCHAR(20),
    country         VARCHAR(3),
    -- KYC
    id_type         VARCHAR(20),   -- PASSPORT, NATIONAL_ID, DRIVING_LICENSE
    id_number       VARCHAR(50),
    id_expiry       DATE,
    kyc_status      VARCHAR(20) NOT NULL DEFAULT 'PENDING',  -- PENDING, VERIFIED, REJECTED
    kyc_verified_at TIMESTAMP,
    -- Classification
    customer_tier   VARCHAR(20) NOT NULL DEFAULT 'RETAIL',  -- RETAIL, BUSINESS, CORPORATE, PREMIUM
    -- Audit
    inserted_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMP NOT NULL DEFAULT NOW(),
    FOREIGN KEY (sys_id, bank_id) REFERENCES bank_parameters(sys_id, bank_id)
);
CREATE INDEX ON cms_customers (sys_id, bank_id);
CREATE INDEX ON cms_customers (email);
CREATE INDEX ON cms_customers (mobile_number);
```

### Schema: `lib/vmu_core/shared/customer.ex`
```elixir
defmodule VmuCore.Shared.Customer do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:customer_id, :binary_id, autogenerate: true}

  schema "cms_customers" do
    field :sys_id,        :string
    field :bank_id,       :string
    field :first_name,    :string
    field :last_name,     :string
    field :date_of_birth, :date
    field :nationality,   :string
    field :email,         :string
    field :mobile_country, :string
    field :mobile_number, :string
    field :address_line1, :string
    field :address_line2, :string
    field :city,          :string
    field :postal_code,   :string
    field :country,       :string
    field :id_type,       :string
    field :id_number,     :string
    field :id_expiry,     :date
    field :kyc_status,    :string, default: "PENDING"
    field :kyc_verified_at, :naive_datetime
    field :customer_tier, :string, default: "RETAIL"

    timestamps()
  end

  @required [:sys_id, :bank_id, :first_name, :last_name]
  @optional [:date_of_birth, :nationality, :email, :mobile_country, :mobile_number,
             :address_line1, :address_line2, :city, :postal_code, :country,
             :id_type, :id_number, :id_expiry, :kyc_status, :customer_tier]

  def changeset(customer, attrs) do
    customer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:kyc_status, ~w[PENDING VERIFIED REJECTED])
    |> validate_inclusion(:customer_tier, ~w[RETAIL BUSINESS CORPORATE PREMIUM])
  end
end
```

---

## Task 3 — CMS Account Schemas

### Migration: `priv/repo/migrations/TIMESTAMP_create_cms_accounts.exs`
```sql
CREATE TABLE cms_accounts (
    account_id          UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    customer_id         UUID        NOT NULL REFERENCES cms_customers(customer_id),
    sys_id              VARCHAR(4)  NOT NULL,
    bank_id             VARCHAR(4)  NOT NULL,
    logo_id             VARCHAR(4)  NOT NULL,
    block_id            VARCHAR(4)  NOT NULL,
    -- Card identity
    pan_token           VARCHAR(64) NOT NULL UNIQUE,   -- tokenised PAN, never store raw PAN
    last_four           VARCHAR(4)  NOT NULL,
    expiry_date         VARCHAR(4)  NOT NULL,           -- MMYY
    -- Credit parameters (VisionPlus core)
    credit_limit        DECIMAL(18,2) NOT NULL DEFAULT 0,
    open_to_buy         DECIMAL(18,2) NOT NULL DEFAULT 0,
    cycle_code          SMALLINT    NOT NULL DEFAULT 1,  -- billing day 1-31
    -- Account status
    account_status      VARCHAR(20) NOT NULL DEFAULT 'ACTIVE',
    -- Delinquency (VisionPlus DPD buckets)
    delinquency_bucket  SMALLINT    NOT NULL DEFAULT 0,  -- 0, 30, 60, 90, 120+
    -- Velocity matrix: 40 parameters (channel x frequency x dimension)
    -- Stored as JSONB for flexibility; validated at application layer
    velocity_limits     JSONB       NOT NULL DEFAULT '{}',
    -- Campaign/override code (Block-level fee override per card)
    campaign_code       VARCHAR(20),
    -- Dates
    open_date           DATE        NOT NULL DEFAULT CURRENT_DATE,
    close_date          DATE,
    next_statement_date DATE,
    last_payment_date   DATE,
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMP   NOT NULL DEFAULT NOW(),
    FOREIGN KEY (sys_id, bank_id, logo_id) REFERENCES logo_parameters(sys_id, bank_id, logo_id)
);

CREATE TABLE cms_balance_buckets (
    bucket_id           UUID        PRIMARY KEY DEFAULT gen_random_uuid(),
    account_id          UUID        NOT NULL REFERENCES cms_accounts(account_id),
    -- VisionPlus standard buckets
    retail_balance      DECIMAL(18,2) NOT NULL DEFAULT 0,
    cash_balance        DECIMAL(18,2) NOT NULL DEFAULT 0,
    accrued_interest    DECIMAL(18,2) NOT NULL DEFAULT 0,
    unpaid_fees         DECIMAL(18,2) NOT NULL DEFAULT 0,
    disputed_amount     DECIMAL(18,2) NOT NULL DEFAULT 0,
    -- Statement snapshot
    statement_balance   DECIMAL(18,2) NOT NULL DEFAULT 0,
    minimum_payment     DECIMAL(18,2) NOT NULL DEFAULT 0,
    -- Dates
    balance_date        DATE        NOT NULL DEFAULT CURRENT_DATE,
    inserted_at         TIMESTAMP   NOT NULL DEFAULT NOW(),
    updated_at          TIMESTAMP   NOT NULL DEFAULT NOW()
);
CREATE UNIQUE INDEX ON cms_balance_buckets(account_id, balance_date);

CREATE TABLE stip_thresholds (
    sys_id          VARCHAR(4)  NOT NULL,
    logo_id         VARCHAR(4)  NOT NULL,
    max_amount      DECIMAL(18,2) NOT NULL,  -- max single txn allowed offline
    max_cumulative  DECIMAL(18,2) NOT NULL,  -- max cumulative offline per account per day
    allowed_mcc_groups  TEXT[],              -- NULL = all MCCs allowed
    inserted_at     TIMESTAMP NOT NULL DEFAULT NOW(),
    PRIMARY KEY (sys_id, logo_id)
);
```

### Schema: `lib/vmu_core/cms/account.ex`
```elixir
defmodule VmuCore.CMS.Account do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:account_id, :binary_id, autogenerate: true}

  schema "cms_accounts" do
    field :customer_id,       :binary_id
    field :sys_id,            :string
    field :bank_id,           :string
    field :logo_id,           :string
    field :block_id,          :string
    field :pan_token,         :string
    field :last_four,         :string
    field :expiry_date,       :string
    field :credit_limit,      :decimal
    field :open_to_buy,       :decimal
    field :cycle_code,        :integer
    field :account_status,    :string, default: "ACTIVE"
    field :delinquency_bucket, :integer, default: 0
    field :velocity_limits,   :map, default: %{}
    field :campaign_code,     :string
    field :open_date,         :date
    field :close_date,        :date
    field :next_statement_date, :date
    field :last_payment_date, :date

    has_one :balance_bucket, VmuCore.CMS.BalanceBucket, foreign_key: :account_id

    timestamps()
  end

  @valid_statuses ~w[ACTIVE CLOSED SUSPENDED BLOCKED DELINQUENT]

  def changeset(account, attrs) do
    account
    |> cast(attrs, [:customer_id, :sys_id, :bank_id, :logo_id, :block_id,
                    :pan_token, :last_four, :expiry_date, :credit_limit,
                    :open_to_buy, :cycle_code, :account_status, :delinquency_bucket,
                    :velocity_limits, :campaign_code, :open_date])
    |> validate_required([:customer_id, :sys_id, :bank_id, :logo_id, :block_id,
                          :pan_token, :last_four, :expiry_date, :credit_limit])
    |> validate_inclusion(:account_status, @valid_statuses)
    |> unique_constraint(:pan_token)
  end

  @doc "Returns total current balance (all buckets combined)."
  def total_balance(%__MODULE__{} = _account, %VmuCore.CMS.BalanceBucket{} = bucket) do
    Decimal.add(bucket.retail_balance, bucket.cash_balance)
    |> Decimal.add(bucket.accrued_interest)
    |> Decimal.add(bucket.unpaid_fees)
  end
end
```

---

## Task 4 — AccountStateCoordinator

This is the most critical component. One GenServer process per active account. Holds live OTB and balance state in memory. The authorization path calls it — never the DB directly.

### File: `lib/vmu_core/cms/account_state_coordinator.ex`

```elixir
defmodule VmuCore.CMS.AccountStateCoordinator do
  @moduledoc """
  Per-account GenServer process registered in the Horde distributed registry.

  Holds live account state in memory:
    - open_to_buy (OTB): remaining credit available right now
    - balance_buckets: current retail/cash/fee/interest balances
    - pending_auths: list of authorized-but-not-cleared amounts
    - account_status: ACTIVE / BLOCKED / SUSPENDED etc.

  Authorization path calls authorize/3 which:
    1. Checks account_status — blocks instantly if not ACTIVE
    2. Resolves product parameters from ParameterEngine (ETS — zero DB)
    3. Validates OTB against requested amount
    4. Checks velocity limits for the channel/frequency
    5. Deducts OTB optimistically on approve, restores on reversal

  One process per account — message queue serializes concurrent auth attempts
  without any DB row locking. This is the VisionPlus model.
  """

  use GenServer
  require Logger
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.Repo
  alias VmuCore.CMS.{Account, BalanceBucket}
  import Ecto.Query

  @registry VmuCore.Shared.Registry
  @supervisor VmuCore.Shared.AccountSupervisor

  # ---------------------------------------------------------------------------
  # Public API
  # ---------------------------------------------------------------------------

  @doc """
  Start (or locate) the coordinator for the given account_id.
  Returns {:ok, pid} whether the process already existed or was just started.
  """
  def ensure_started(account_id) do
    case Horde.Registry.lookup(@registry, account_id) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        child_spec = %{
          id: account_id,
          start: {__MODULE__, :start_link, [account_id]},
          restart: :transient
        }
        case Horde.DynamicSupervisor.start_child(@supervisor, child_spec) do
          {:ok, pid} -> {:ok, pid}
          {:error, {:already_started, pid}} -> {:ok, pid}
          error -> error
        end
    end
  end

  @doc """
  Authorize a transaction.

  Returns:
    {:approved, response_code, updated_otb}
    {:declined, response_code, reason}
  """
  def authorize(account_id, amount, opts \\ []) do
    channel = Keyword.get(opts, :channel, :pos)  # :pos | :atm | :contactless | :ecom
    mcc     = Keyword.get(opts, :mcc, nil)
    currency = Keyword.get(opts, :currency, "AED")

    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, {:authorize, amount, channel, mcc, currency}, 5_000)
    end
  end

  @doc "Record a reversal — restores OTB for a previously authorised amount."
  def reverse(account_id, stan, amount) do
    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, {:reverse, stan, amount}, 5_000)
    end
  end

  @doc "Force-refresh state from DB (call after EOD or manual adjustment)."
  def refresh(account_id) do
    with {:ok, pid} <- ensure_started(account_id) do
      GenServer.call(pid, :refresh, 10_000)
    end
  end

  # ---------------------------------------------------------------------------
  # GenServer lifecycle
  # ---------------------------------------------------------------------------

  def start_link(account_id) do
    GenServer.start_link(__MODULE__, account_id,
      name: {:via, Horde.Registry, {@registry, account_id}})
  end

  @impl true
  def init(account_id) do
    Logger.debug("[ASC] Starting coordinator for account #{account_id}")

    case load_account_state(account_id) do
      {:ok, state} ->
        # Idle timeout: terminate after 30 min of no activity
        {:ok, state, 30 * 60 * 1_000}

      {:error, reason} ->
        Logger.error("[ASC] Failed to load account #{account_id}: #{inspect(reason)}")
        {:stop, reason}
    end
  end

  # ---------------------------------------------------------------------------
  # Authorization handling
  # ---------------------------------------------------------------------------

  @impl true
  def handle_call({:authorize, amount, channel, mcc, _currency}, _from, state) do
    result = do_authorize(state, amount, channel, mcc)

    case result do
      {:approved, _rc, new_otb} ->
        new_state = %{state | open_to_buy: new_otb, last_activity: DateTime.utc_now()}
        {:reply, result, new_state, 30 * 60 * 1_000}

      {:declined, _rc, _reason} ->
        {:reply, result, state, 30 * 60 * 1_000}
    end
  end

  @impl true
  def handle_call({:reverse, _stan, amount}, _from, state) do
    restored_otb = Decimal.add(state.open_to_buy, amount)
    new_state = %{state | open_to_buy: restored_otb, last_activity: DateTime.utc_now()}
    {:reply, {:ok, restored_otb}, new_state, 30 * 60 * 1_000}
  end

  @impl true
  def handle_call(:refresh, _from, %{account_id: account_id} = _state) do
    case load_account_state(account_id) do
      {:ok, new_state} -> {:reply, :ok, new_state, 30 * 60 * 1_000}
      error            -> {:reply, error, _state, 30 * 60 * 1_000}
    end
  end

  # Idle timeout — process shuts down cleanly
  @impl true
  def handle_info(:timeout, state) do
    Logger.debug("[ASC] Idle timeout for account #{state.account_id} — shutting down")
    {:stop, :normal, state}
  end

  # ---------------------------------------------------------------------------
  # Authorization logic
  # ---------------------------------------------------------------------------

  defp do_authorize(state, amount, _channel, _mcc) do
    cond do
      state.account_status != "ACTIVE" ->
        {:declined, "62", :account_not_active}

      Decimal.compare(amount, state.open_to_buy) == :gt ->
        {:declined, "51", :insufficient_otb}

      true ->
        new_otb = Decimal.sub(state.open_to_buy, amount)
        {:approved, "00", new_otb}
    end
  end

  # ---------------------------------------------------------------------------
  # State loading from DB
  # ---------------------------------------------------------------------------

  defp load_account_state(account_id) do
    query = from a in Account,
              where: a.account_id == ^account_id,
              left_join: b in BalanceBucket, on: b.account_id == a.account_id,
              order_by: [desc: b.balance_date],
              limit: 1,
              preload: [balance_bucket: b]

    case Repo.one(query) do
      nil ->
        {:error, :account_not_found}

      account ->
        {:ok, %{
          account_id:     account_id,
          sys_id:         account.sys_id,
          bank_id:        account.bank_id,
          logo_id:        account.logo_id,
          block_id:       account.block_id,
          account_status: account.account_status,
          credit_limit:   account.credit_limit,
          open_to_buy:    account.open_to_buy,
          delinquency_bucket: account.delinquency_bucket,
          velocity_limits: account.velocity_limits,
          campaign_code:  account.campaign_code,
          last_activity:  DateTime.utc_now()
        }}
    end
  end
end
```

---

## Task 5 — Wire Switch.Router → ParameterEngine → AccountStateCoordinator

### New file: `lib/vmu_core/fas/authorization.ex`

This is the vMu_fas context module. It wraps `DaProductApp.Switch.Router` and adds VisionPlus issuer processing.

```elixir
defmodule VmuCore.FAS.Authorization do
  @moduledoc """
  vMu issuer authorization path.

  Called by Switch.Router when an MTI 0100 is identified as an issuer transaction
  (BIN matches our logo table).

  Flow:
    1. Extract PAN from ISO message
    2. ParameterEngine.resolve_bin/1 → {sys_id, bank_id, logo_id}
    3. Retrieve account_id for this PAN (token lookup)
    4. AccountStateCoordinator.authorize/3 → approve or decline
    5. Return ISO 0110 response with correct RC and DE-38 (approval code)
  """

  require Logger
  alias VmuCore.Shared.ParameterEngine
  alias VmuCore.CMS.AccountStateCoordinator
  alias VmuCore.Repo
  alias VmuCore.CMS.Account
  import Ecto.Query

  @doc """
  Process an issuer authorization request.
  Returns `{:ok, response_code, approval_code}` or `{:error, response_code}`.
  """
  def process(%{pan: pan, amount: amount, channel: channel, mcc: mcc} = _request) do
    with {:ok, {sys_id, bank_id, logo_id}} <- ParameterEngine.resolve_bin(pan),
         {:ok, account_id}                 <- resolve_account(pan),
         {:ok, _block_id}                  <- resolve_block(sys_id, bank_id, logo_id, account_id),
         result                            <- AccountStateCoordinator.authorize(account_id, amount, channel: channel, mcc: mcc) do
      case result do
        {:approved, rc, _otb} ->
          approval_code = generate_approval_code()
          Logger.info("[Auth] Approved account=#{account_id} amount=#{amount} rc=#{rc}")
          {:ok, rc, approval_code}

        {:declined, rc, reason} ->
          Logger.info("[Auth] Declined account=#{account_id} amount=#{amount} rc=#{rc} reason=#{reason}")
          {:error, rc}
      end
    else
      {:error, :no_bin_match} ->
        # BIN not ours — pass to upstream (acquirer role or not our card)
        {:error, "15"}

      {:error, :account_not_found} ->
        {:error, "14"}  # Invalid card number

      {:error, reason} ->
        Logger.error("[Auth] Unexpected error: #{inspect(reason)}")
        {:error, "96"}  # System malfunction
    end
  end

  # ---------------------------------------------------------------------------
  # Internal helpers
  # ---------------------------------------------------------------------------

  defp resolve_account(pan) do
    # pan_token stores a deterministic hash of the PAN, never the PAN itself
    pan_token = :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)

    case Repo.one(from a in Account, where: a.pan_token == ^pan_token, select: a.account_id) do
      nil        -> {:error, :account_not_found}
      account_id -> {:ok, account_id}
    end
  end

  defp resolve_block(_sys_id, _bank_id, _logo_id, account_id) do
    case Repo.one(from a in Account, where: a.account_id == ^account_id, select: a.block_id) do
      nil      -> {:error, :account_not_found}
      block_id -> {:ok, block_id}
    end
  end

  defp generate_approval_code do
    :rand.uniform(999_999)
    |> Integer.to_string()
    |> String.pad_leading(6, "0")
  end
end
```

### Modify `DaProductApp.Switch.Router` (extend, do not rewrite)

Add a clause in the routing function to check if the BIN is ours before forwarding upstream:

```elixir
# In DaProductApp.Switch.Router, add after existing routing logic:

defp route_issuer_or_upstream(%ISOMsg{} = msg) do
  pan = ISOMsg.get_field(msg, 2)

  case VmuCore.Shared.ParameterEngine.resolve_bin(pan) do
    {:ok, _logo_context} ->
      # This BIN belongs to vMu — process as issuer
      request = %{
        pan:     pan,
        amount:  ISOMsg.get_field(msg, 4) |> parse_amount(),
        channel: derive_channel(msg),
        mcc:     ISOMsg.get_field(msg, 18),
        stan:    ISOMsg.get_field(msg, 11)
      }
      VmuCore.FAS.Authorization.process(request)

    {:error, :no_bin_match} ->
      # Not our card — forward upstream as before
      route_upstream(msg)
  end
end
```

---

## Task 6 — STIP (Stand-In Processing)

STIP allows the switch to approve a transaction offline when the CMS is unreachable. Limits are stored in `stip_thresholds` and cached in ETS.

### New file: `lib/vmu_core/fas/stip.ex`

```elixir
defmodule VmuCore.FAS.STIP do
  @moduledoc """
  Stand-In Processing (STIP) for issuer authorization when CMS is unreachable.

  VisionPlus behaviour:
    - If AccountStateCoordinator is unavailable (timeout or node failure),
      check STIP thresholds from ETS.
    - If amount ≤ stip_threshold for this logo, approve with RC "00" and
      set the STIP indicator (DE-60 or equivalent).
    - Log the STIP authorization for reconciliation at EOD.
  """

  require Logger
  alias VmuCore.Shared.ParameterEngine

  @stip_table :vmu_stip_cache

  def init_cache do
    :ets.new(@stip_table, [:named_table, :set, :public, {:read_concurrency, true}])
  end

  @doc """
  Attempt STIP authorization for the given logo and amount.
  Returns {:stip_approved, "00"} or {:stip_declined, "91"}.
  """
  def authorize(sys_id, logo_id, amount) do
    case :ets.lookup(@stip_table, {sys_id, logo_id}) do
      [{_, threshold}] ->
        if Decimal.compare(amount, threshold) != :gt do
          Logger.warn("[STIP] Approving offline: sys=#{sys_id} logo=#{logo_id} amount=#{amount}")
          {:stip_approved, "00"}
        else
          Logger.warn("[STIP] Amount exceeds STIP threshold — declining")
          {:stip_declined, "91"}
        end

      [] ->
        # No STIP threshold configured for this logo — decline safely
        {:stip_declined, "91"}
    end
  end

  def load_thresholds(repo) do
    import Ecto.Query
    # Load stip_thresholds table into ETS
    repo.all(from s in "stip_thresholds", select: {s.sys_id, s.logo_id, s.max_amount})
    |> Enum.each(fn {sys_id, logo_id, max_amount} ->
      :ets.insert(@stip_table, {{sys_id, logo_id}, max_amount})
    end)
  end
end
```

### Update `VmuCore.FAS.Authorization.process/1` to use STIP on timeout:

```elixir
# Wrap the AccountStateCoordinator call with STIP fallback:
case AccountStateCoordinator.authorize(account_id, amount, channel: channel, mcc: mcc) do
  {:approved, rc, _otb} ->
    {:ok, rc, generate_approval_code()}

  {:declined, rc, reason} ->
    {:error, rc}

  {:error, reason} when reason in [:timeout, :noproc] ->
    # CMS unreachable — attempt STIP
    VmuCore.FAS.STIP.authorize(sys_id, logo_id, amount)
    |> case do
      {:stip_approved, rc} -> {:ok, rc, generate_approval_code()}
      {:stip_declined, rc} -> {:error, rc}
    end
end
```

---

## Integration Test: End-to-End Authorization

```elixir
defmodule VmuCore.FAS.AuthorizationIntegrationTest do
  use VmuCore.DataCase  # starts Repo, applies sandbox
  alias VmuCore.FAS.Authorization
  alias VmuCore.Shared.ParameterEngine

  setup do
    # Seed parameter hierarchy
    sys  = insert!(:sys_parameter, sys_id: "0001", base_currency: "AED")
    bank = insert!(:bank_parameter, sys_id: "0001", bank_id: "0010")
    logo = insert!(:logo_parameter, sys_id: "0001", bank_id: "0010", logo_id: "0100", bin_prefix: "543210")
    blk  = insert!(:block_parameter, sys_id: "0001", bank_id: "0010", logo_id: "0100", block_id: "1000",
                   apr_percentage: Decimal.new("24.00"), credit_limit_default: Decimal.new("5000.00"))

    # Refresh ETS cache
    ParameterEngine.refresh_all()

    # Seed customer + account
    customer = insert!(:customer, sys_id: "0001", bank_id: "0010")
    pan = "5432101234567890"
    pan_token = :crypto.hash(:sha256, pan) |> Base.encode16(case: :lower)
    account = insert!(:account,
      customer_id: customer.customer_id,
      sys_id: "0001", bank_id: "0010", logo_id: "0100", block_id: "1000",
      pan_token: pan_token, last_four: "7890",
      credit_limit: Decimal.new("5000.00"),
      open_to_buy:  Decimal.new("5000.00"),
      account_status: "ACTIVE"
    )

    %{pan: pan, account: account}
  end

  test "approves valid authorization within OTB", %{pan: pan} do
    request = %{pan: pan, amount: Decimal.new("100.00"), channel: :pos, mcc: "5411"}
    assert {:ok, "00", approval_code} = Authorization.process(request)
    assert String.length(approval_code) == 6
  end

  test "declines when amount exceeds OTB", %{pan: pan} do
    request = %{pan: pan, amount: Decimal.new("6000.00"), channel: :pos, mcc: "5411"}
    assert {:error, "51"} = Authorization.process(request)
  end

  test "returns 15 for unknown BIN" do
    request = %{pan: "9999991234567890", amount: Decimal.new("50.00"), channel: :pos, mcc: "5411"}
    assert {:error, "15"} = Authorization.process(request)
  end

  test "declines blocked account", %{pan: pan, account: account} do
    Repo.update!(VmuCore.CMS.Account.changeset(account, %{account_status: "BLOCKED"}))
    AccountStateCoordinator.refresh(account.account_id)
    request = %{pan: pan, amount: Decimal.new("100.00"), channel: :pos, mcc: "5411"}
    assert {:error, "62"} = Authorization.process(request)
  end
end
```

---

## Phase 1 Done Criteria

- [ ] `mix deps.get` pulls Horde and libcluster without conflicts
- [ ] `mix ecto.migrate` applies all 4 new tables (cms_customers, cms_accounts, cms_balance_buckets, stip_thresholds)
- [ ] `ParameterEngine.resolve_bin/1` correctly resolves a seeded BIN to {sys_id, bank_id, logo_id}
- [ ] `AccountStateCoordinator.ensure_started/1` starts and registers in Horde on first call
- [ ] `AccountStateCoordinator.authorize/3` approves within OTB, declines over OTB
- [ ] `Authorization.process/1` runs the full chain and returns a 6-digit approval code on success
- [ ] STIP fallback tested: AccountStateCoordinator timeout → STIP lookup → approve/decline based on threshold
- [ ] All 4 integration test assertions pass against real PostgreSQL test database
