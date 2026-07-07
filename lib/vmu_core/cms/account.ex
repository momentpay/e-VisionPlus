defmodule VmuCore.CMS.Account do
  @moduledoc """
  CMS Account Base Segment (ABS) — the central CMS record for a cardholder account.

  ## Field Groups

  - **Identity**: customer_id, sys_id, bank_id, logo_id, block_id
  - **Card**: pan_token (SHA-256), last_four, expiry_date, emboss_name
  - **Credit**: credit_limit, open_to_buy, cash_limit, cash_open_to_buy
  - **Status**: account_status, block_code, block_reason, blocked_at
  - **Billing**: cycle_code, delinquency_bucket, next_statement_date, last_payment_date
  - **Config**: velocity_limits (JSONB), campaign_code

  ## block_code vs account_status

  `account_status` captures the lifecycle state (ACTIVE/CLOSED/SUSPENDED/DELINQUENT).
  `block_code` captures the operational restriction reason:
    - `L` — Lost card
    - `S` — Stolen card
    - `F` — Fraud suspicion
    - `C` — Collections hold
    - `O` — Overlimit restriction
    - `nil` — No block active

  An account can be ACTIVE in status but blocked for card operations via block_code.
  Every block_code change must also insert a row in `block_code_history`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.CMS.BalanceBucket

  @primary_key {:account_id, :binary_id, autogenerate: true}

  schema "cms_accounts" do
    field :customer_id,         :binary_id
    field :sys_id,              :string
    field :bank_id,             :string
    field :logo_id,             :string
    field :block_id,            :string

    # ── Card ────────────────────────────────────────────────────────────────────
    field :pan_token,           :string  # SHA-256 of raw PAN — raw PAN never stored
    field :last_four,           :string
    field :expiry_date,         :string  # MMYY format
    field :emboss_name,         :string  # Card face name, max 26 chars, uppercase

    # ── Credit ──────────────────────────────────────────────────────────────────
    field :credit_limit,        :decimal
    field :open_to_buy,         :decimal
    field :cash_limit,          :decimal  # Cash sub-limit (typically 30% of credit_limit)
    field :cash_open_to_buy,    :decimal  # Remaining cash advance capacity

    # ── Billing ─────────────────────────────────────────────────────────────────
    field :cycle_code,          :integer, default: 1  # Day of month for billing
    field :delinquency_bucket,  :integer, default: 0  # 0/30/60/90/120+
    # Penalty APR persistence (CMS-G1 ADR-C2): once triggered, penalty pricing
    # holds until the logo's penalty_apr_cure_rule is satisfied
    field :penalty_apr_active,  :boolean, default: false
    field :penalty_cure_cycles, :integer, default: 0
    field :next_statement_date, :date
    field :last_payment_date,   :date
    field :open_date,           :date
    field :close_date,          :date
    # Lifecycle (CMS-G3): closure pending until zero balance; dormancy flag
    field :closure_requested_at, :utc_datetime
    field :dormant_since,        :date

    # ── Status ──────────────────────────────────────────────────────────────────
    field :account_status,      :string, default: "ACTIVE"
    # Operational block code (distinct from lifecycle status)
    field :block_code,          :string  # L|S|F|C|O or nil
    field :block_reason,        :string  # Human-readable reason for current block
    field :blocked_at,          :naive_datetime

    # ── Config ──────────────────────────────────────────────────────────────────
    field :velocity_limits,     :map, default: %{}
    field :campaign_code,       :string

    has_one :balance_bucket, BalanceBucket, foreign_key: :account_id

    timestamps()
  end

  @valid_statuses  ~w[ACTIVE CLOSED SUSPENDED BLOCKED DELINQUENT POSTING]
  @valid_block_codes ~w[L S F C O]

  @required [:customer_id, :sys_id, :bank_id, :logo_id, :block_id,
             :pan_token, :last_four, :expiry_date, :credit_limit]
  @optional [:open_to_buy, :cash_limit, :cash_open_to_buy,
             :cycle_code, :account_status, :delinquency_bucket,
             :penalty_apr_active, :penalty_cure_cycles,
             :next_statement_date, :last_payment_date, :open_date, :close_date,
             :closure_requested_at, :dormant_since,
             :velocity_limits, :campaign_code,
             :emboss_name, :block_code, :block_reason, :blocked_at]

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:account_status, @valid_statuses)
    |> validate_inclusion(:block_code, @valid_block_codes,
         message: "must be one of L, S, F, C, O")
    |> validate_length(:emboss_name, max: 26)
    |> validate_length(:block_reason, max: 100)
    |> unique_constraint(:pan_token)
  end

  @doc "Returns total outstanding balance across all buckets."
  def total_balance(%__MODULE__{balance_bucket: %BalanceBucket{} = b}), do: BalanceBucket.total(b)
  def total_balance(%__MODULE__{}), do: Decimal.new(0)

  @doc "Returns true if a block code is currently active on this account."
  def blocked?(%__MODULE__{block_code: nil}), do: false
  def blocked?(%__MODULE__{}), do: true
end
