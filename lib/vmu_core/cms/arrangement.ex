defmodule VmuCore.CMS.Arrangement do
  @moduledoc """
  Koṣa domain-model alignment (`docs/cms/core-domain-new-docs.md`,
  2026-07-28) — one row per customer-relationship, indexing across
  `CMS.Account` (credit), `CMS.DebitAccount`, `CMS.PrepaidAccount`, and
  `HCS.EmployeeCard`/`FleetCard` without changing any of them.

  Deliberately thin: no `status`, no balance. Those stay authoritative
  on the real product row (`account_ref`, read live) — never duplicated
  here, where they could silently drift out of sync.

  `account_ref` is a plain string, not `:binary_id` — `CMS.Account`/
  `DebitAccount`/`PrepaidAccount` key on UUID, but `HCS.Company`/
  `EmployeeCard`/`FleetCard` predate that convention and use plain
  integer primary keys (found live wiring this in), so no single
  strongly-typed column can hold both.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @product_types ~w[CREDIT DEBIT PREPAID CORPORATE_FACILITY CORPORATE_EMPLOYEE CORPORATE_FLEET WALLET]

  schema "cms_arrangements" do
    field :customer_id,  :binary_id
    field :product_type, :string
    field :account_ref,  :string
    field :opened_at,    :date

    timestamps(type: :utc_datetime)
  end

  @required ~w[customer_id product_type account_ref opened_at]a

  def changeset(arrangement, attrs) do
    arrangement
    |> cast(attrs, @required)
    |> validate_required(@required)
    |> validate_inclusion(:product_type, @product_types)
    |> unique_constraint([:product_type, :account_ref])
  end

  def product_types, do: @product_types
end
