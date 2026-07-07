defmodule VmuCore.CMS.SupplementaryCard do
  @moduledoc """
  Supplementary (additional) card relationship record.

  A SupplementaryCard links a child CMS account (supplementary cardholder) to
  a parent CMS account (primary cardholder). Both are full `cms_accounts` rows
  with independent PANs, block codes, and card statuses.

  All balances from supplementary card transactions accrue to the **primary**
  account's balance buckets. The supplementary card shares the primary account's
  credit limit and billing cycle.

  ## Sub-limit

  When `sub_limit` is set, the supplementary cardholder's spending is capped at
  that amount independently of the primary open_to_buy. This is enforced in
  `AccountStateCoordinator` by treating `sub_limit` like a secondary OTB check.

  ## Usage

      # Issue a supplementary card
      {:ok, rel} = SupplementaryCard.create(primary_account_id, supplementary_account_id,
                     sub_limit: Decimal.new("5000.00"))

      # List all supplementary cards for a primary
      cards = SupplementaryCard.list_for_primary(primary_account_id)

      # Find the primary account for a supplementary card
      {:ok, primary_id} = SupplementaryCard.primary_for(supplementary_account_id)
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  @relationship_types ~w[SUPPLEMENTARY]
  @valid_statuses     ~w[ACTIVE SUSPENDED CLOSED]

  schema "supplementary_cards" do
    field :primary_account_id,       :binary_id
    field :supplementary_account_id, :binary_id
    field :relationship_type,        :string, default: "SUPPLEMENTARY"
    field :sub_limit,                :decimal
    field :status,                   :string, default: "ACTIVE"
    field :activated_at,             :naive_datetime

    timestamps()
  end

  @type t :: %__MODULE__{}

  @required [:primary_account_id, :supplementary_account_id]
  @optional [:relationship_type, :sub_limit, :status, :activated_at]

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:relationship_type, @relationship_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_number(:sub_limit, greater_than: 0)
    |> validate_not_self_reference()
    |> unique_constraint(:supplementary_account_id,
         name: :supplementary_cards_child_unique_idx,
         message: "this account is already a supplementary card on another primary account")
  end

  # ── Public Helpers ───────────────────────────────────────────────────────────

  @doc """
  Create a supplementary card relationship.

  ## Options
    - `:sub_limit` — Decimal spending limit for the supplementary card (optional)
  """
  @spec create(Ecto.UUID.t(), Ecto.UUID.t(), keyword()) ::
          {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(primary_account_id, supplementary_account_id, opts \\ []) do
    attrs = %{
      primary_account_id:       primary_account_id,
      supplementary_account_id: supplementary_account_id,
      sub_limit:                Keyword.get(opts, :sub_limit),
      activated_at:             NaiveDateTime.utc_now()
    }

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Returns all supplementary cards linked to a primary account.
  """
  @spec list_for_primary(Ecto.UUID.t()) :: [t()]
  def list_for_primary(primary_account_id) do
    Repo.all(
      from s in __MODULE__,
        where: s.primary_account_id == ^primary_account_id
          and s.status != "CLOSED",
        order_by: [asc: s.inserted_at]
    )
  end

  @doc """
  Finds the primary account ID for a given supplementary account.
  Returns `{:ok, primary_account_id}` or `{:error, :not_supplementary}`.
  """
  @spec primary_for(Ecto.UUID.t()) :: {:ok, Ecto.UUID.t()} | {:error, :not_supplementary}
  def primary_for(supplementary_account_id) do
    case Repo.one(
      from s in __MODULE__,
        where: s.supplementary_account_id == ^supplementary_account_id,
        select: s.primary_account_id
    ) do
      nil -> {:error, :not_supplementary}
      pid -> {:ok, pid}
    end
  end

  @doc """
  Looks up the supplementary relationship for an account_id.

  Returns `{primary_account_id, sub_limit_or_nil}` when the account is an
  active supplementary card, or `nil` when it is a primary (standalone) account.

  Called on every authorization to detect supplementary cards — the query
  hits a unique index on `supplementary_account_id`, so it is a single
  index-seek even on large tables.
  """
  @spec lookup_by_account(Ecto.UUID.t()) :: {Ecto.UUID.t(), Decimal.t() | nil} | nil
  def lookup_by_account(account_id) do
    Repo.one(
      from s in __MODULE__,
        where: s.supplementary_account_id == ^account_id and s.status == "ACTIVE",
        select: {s.primary_account_id, s.sub_limit}
    )
  end

  @doc """
  Returns the effective spending limit for a supplementary card:
  the sub_limit if set, or nil (meaning primary OTB governs).
  """
  @spec effective_sub_limit(t()) :: Decimal.t() | nil
  def effective_sub_limit(%__MODULE__{sub_limit: sl}), do: sl

  # ── Private ─────────────────────────────────────────────────────────────────

  defp validate_not_self_reference(changeset) do
    primary = get_field(changeset, :primary_account_id)
    suppl   = get_field(changeset, :supplementary_account_id)

    if primary && suppl && primary == suppl do
      add_error(changeset, :supplementary_account_id, "cannot be the same as primary_account_id")
    else
      changeset
    end
  end
end
