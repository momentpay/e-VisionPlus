defmodule VmuCore.CMS.AutopayMandate do
  @moduledoc """
  Standing payment instruction (CMS-G2.2, FR-CMS-065).

  One ACTIVE mandate per account (partial unique index). Types:
  - `MIN_DUE` — pay the statement minimum on due date
  - `FULL`    — pay the full statement balance
  - `FIXED`   — pay `fixed_amount` (capped at statement balance at run time)

  Executed by `VmuCore.CMS.Oban.AutopayRunJob` through the `direct_debit`
  channel with reference `"autopay:<account>:<due_date>"` — idempotent per
  cycle by construction.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:mandate_id, :binary_id, autogenerate: true}

  @types ~w[MIN_DUE FULL FIXED]

  schema "cms_autopay_mandates" do
    field :account_id,        :binary_id
    field :mandate_type,      :string
    field :fixed_amount,      :decimal
    field :funding_reference, :string
    field :active,            :boolean, default: true
    field :cancelled_at,      :utc_datetime

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[account_id mandate_type]a
  @optional ~w[fixed_amount funding_reference active cancelled_at]a

  def changeset(mandate, attrs) do
    mandate
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:mandate_type, @types)
    |> validate_fixed_amount()
    |> unique_constraint(:account_id,
         name: :cms_autopay_mandates_account_id_index,
         message: "account already has an active mandate")
  end

  defp validate_fixed_amount(cs) do
    if get_field(cs, :mandate_type) == "FIXED" and is_nil(get_field(cs, :fixed_amount)) do
      add_error(cs, :fixed_amount, "required for FIXED mandates")
    else
      cs
    end
  end

  def types, do: @types
end
