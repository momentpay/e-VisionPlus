defmodule VmuCore.CMS.TransactionAllocation do
  @moduledoc """
  Ecto schema for `cms_transaction_allocations` (FR-067) — one row per
  individual purchase/cash-advance transaction that creates outstanding
  balance, tracked separately from (but kept in sync with)
  `VmuCore.CMS.BalanceBucket`'s aggregate bucket totals.

  Created by `VmuCore.CMS.PurchasePosting.post/1`; paid down by
  `VmuCore.CMS.PaymentAllocation.allocate_payment/4`. See both modules'
  docs for the full picture — this file is schema + simple query helpers
  only.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:allocation_id, :binary_id, autogenerate: true}

  @valid_bucket_fields ~w[retail_balance cash_balance bt_balance]
  @valid_statuses ~w[OUTSTANDING PARTIALLY_PAID PAID]

  schema "cms_transaction_allocations" do
    field :account_id,           :binary_id
    field :trams_transaction_id, :binary_id
    field :bucket_field,         :string
    field :original_amount,      :decimal
    field :allocated_amount,     :decimal, default: Decimal.new(0)
    field :remaining_amount,     :decimal
    field :status,               :string, default: "OUTSTANDING"
    field :transaction_date,     :date
    field :disputed,             :boolean, default: false
    field :idempotency_key,      :string

    timestamps()
  end

  @required [:account_id, :bucket_field, :original_amount, :remaining_amount,
             :transaction_date, :idempotency_key]
  @optional [:trams_transaction_id, :allocated_amount, :status, :disputed]

  def changeset(allocation, attrs) do
    allocation
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:bucket_field, @valid_bucket_fields)
    |> validate_inclusion(:status, @valid_statuses)
    |> unique_constraint(:idempotency_key)
  end

  @doc """
  Outstanding (not fully paid) allocations for an account/bucket, ordered
  per `method` (`:fifo` oldest-first, `:lifo` newest-first,
  `:highest_amount_first`, `:proportional` — same order as `:fifo` for
  listing purposes, `PaymentAllocation` spreads pro-rata across all of
  them). Excludes `disputed: true` rows when `exclude_disputed` is true.
  """
  @spec outstanding(Ecto.UUID.t(), String.t(), atom(), boolean()) :: [t()]
  def outstanding(account_id, bucket_field, method \\ :fifo, exclude_disputed \\ true) do
    query =
      from a in __MODULE__,
        where:
          a.account_id == ^account_id and a.bucket_field == ^bucket_field and
            a.status != "PAID"

    query = if exclude_disputed, do: where(query, [a], a.disputed == false), else: query

    query =
      case method do
        :lifo -> order_by(query, [a], desc: a.transaction_date, desc: a.inserted_at)
        :highest_amount_first -> order_by(query, [a], desc: a.remaining_amount)
        _ -> order_by(query, [a], asc: a.transaction_date, asc: a.inserted_at)
      end

    Repo.all(query)
  end

  @doc "All allocations for an account, newest first — for ops/statement display."
  @spec list_for_account(Ecto.UUID.t(), String.t() | nil) :: [t()]
  def list_for_account(account_id, bucket_field \\ nil) do
    query = from a in __MODULE__, where: a.account_id == ^account_id, order_by: [desc: a.transaction_date]
    query = if bucket_field, do: where(query, [a], a.bucket_field == ^bucket_field), else: query
    Repo.all(query)
  end

  @type t :: %__MODULE__{}
end
