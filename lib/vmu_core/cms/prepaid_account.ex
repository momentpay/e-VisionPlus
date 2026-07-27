defmodule VmuCore.CMS.PrepaidAccount do
  @moduledoc """
  Closed-loop stored-value account (Way4 parity plan Phase 1 item 5,
  2026-07-27) — real, network-issued Debit's opposite number: no linked
  external deposit account, no credit line. The card's balance *is* the
  account. Deliberately has no `available_balance` field — see
  `CMS.PrepaidLedger` — the balance is always derived from
  `CMS.PrepaidLedgerEntry` (sum of active, unexpired LOAD rows), never a
  mutated counter, because value expires per-load (dormancy/FR-005).

  Distinct from `CMS.DebitAccount`: a debit card draws down a real
  demand-deposit balance via a genuine network scheme; a prepaid card's
  value is self-contained on the program/instrument itself, issued
  through this repo's own closed-loop pipeline (same FAS→TRAMS→GL
  pipeline every product uses, just an internal/on-us clearing source).
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:prepaid_account_id, :binary_id, autogenerate: true}

  @valid_statuses ~w[ACTIVE SUSPENDED CLOSED DORMANT]

  schema "cms_prepaid_accounts" do
    field :customer_id,  :binary_id
    field :sys_id,       :string
    field :bank_id,      :string
    field :logo_id,      :string
    field :block_id,     :string

    field :currency,     :string, default: "AED"
    field :status,       :string, default: "ACTIVE"
    field :opened_at,    :date
    field :closed_at,    :date

    timestamps(type: :utc_datetime)
  end

  @required ~w[customer_id sys_id bank_id logo_id block_id opened_at]a
  @optional ~w[currency status closed_at]a

  def changeset(account, attrs) do
    account
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @valid_statuses)
  end

  def active?(%__MODULE__{status: "ACTIVE"}), do: true
  def active?(%__MODULE__{}), do: false
end
