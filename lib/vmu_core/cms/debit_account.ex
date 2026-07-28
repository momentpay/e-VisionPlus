defmodule VmuCore.CMS.DebitAccount do
  @moduledoc """
  Real, network-issued debit account (Way4 parity plan Phase 1 item 4,
  2026-07-26) — a genuine Visa/Mastercard-scheme card drawing down a real
  demand-deposit balance, not `CMS.Account`'s credit-line model and not
  the closed-loop Prepaid wallet product.

  Deliberately a separate schema from `CMS.Account`, not a shared-table
  discriminator — see `docs/debit/DEBIT_Module_Requirements.md` §7.4/§9
  for the full reasoning: `CMS.Account.credit_limit` is `NOT NULL` and
  every downstream OTB/delinquency/statement calculation assumes it's
  real. A debit account has no credit_limit, no OTB, no billing cycle at
  all — `available_balance` is a deposit liability, not a receivable
  asset, so it never enters any of `cms_accounts`' EOD jobs.

  Shares the same SYS→BANK→LOGO→BLOCK identity fields as every other
  product so `ParameterEngine`/FAS routing and market-specific
  regulatory config (`BankParameter.regulatory_regime`) work unchanged.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:debit_account_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[ACTIVE SUSPENDED CLOSED DORMANT]
  @valid_kyc_statuses ~w[PENDING VERIFIED REJECTED]

  schema "cms_debit_accounts" do
    field :customer_id,        :binary_id
    field :sys_id,             :string
    field :bank_id,            :string
    field :logo_id,            :string
    field :block_id,           :string

    field :available_balance,  :decimal, default: Decimal.new(0)
    field :currency,           :string, default: "AED"
    field :status,             :string, default: "ACTIVE"
    field :opened_at,          :date
    field :closed_at,          :date

    # Card Products UX Parity Phase 1e (2026-07-28) — Debit's own copies
    # of Credit's account-level Block/velocity-limits/KYC fields (see
    # docs/compare/Card_Products_UX_Parity_Tracker.md §6). block_code/
    # block_reason/blocked_at mirror CMS.Account's shape exactly, kept
    # in sync by CMS.DebitBlockHistory.record_block/6 the same way
    # BlockCodeHistory keeps CMS.Account in sync.
    field :block_code,         :string
    field :block_reason,       :string
    field :blocked_at,         :naive_datetime
    field :velocity_limits,    :map, default: %{}
    field :kyc_status,         :string, default: "PENDING"
    field :kyc_verified_at,    :naive_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w[customer_id sys_id bank_id logo_id block_id opened_at]a
  @optional ~w[available_balance currency status closed_at
               block_code block_reason blocked_at velocity_limits
               kyc_status kyc_verified_at]a

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_inclusion(:kyc_status, @valid_kyc_statuses)
    |> validate_number(:available_balance, greater_than_or_equal_to: 0)
  end

  def active?(%__MODULE__{status: "ACTIVE"}), do: true
  def active?(%__MODULE__{}), do: false
end
