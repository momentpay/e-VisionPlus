defmodule VmuCore.MBS.Merchant do
  @moduledoc """
  MBS (Merchant Banking Services) merchant hierarchy.

  A merchant is the top-level entity in the MBS hierarchy:
    Merchant (chain) → Terminal (POS/ATM) → Transaction

  merchant_type:
    CHAIN      — multi-location retail chain (parent for terminals at multiple sites)
    STANDALONE — single-location merchant
    VIRTUAL    — e-commerce / MOTO merchant with no physical terminals

  settlement_iban is mandatory for CHAIN and STANDALONE merchants — used by
  the settlement_core reconciliation process. VIRTUAL merchants may have a
  wallet address instead (stored in settlement_bank field).

  MCC (Merchant Category Code) drives:
    - Authorization velocity rules (ParameterEngine block/logo)
    - MDR tier selection in MdrEngine
    - Dispute category routing in DPS
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:merchant_id, :binary_id, autogenerate: true}

  schema "mbs_merchants" do
    field :sys_id,          :string
    field :bank_id,         :string
    field :merchant_name,   :string
    field :merchant_type,   :string   # CHAIN | STANDALONE | VIRTUAL
    field :mcc,             :string
    field :registration_no, :string
    field :vat_no,          :string
    field :settlement_bank, :string
    field :settlement_iban, :string
    field :mdr_template_id, :string
    field :status,          :string, default: "ACTIVE"

    has_many :terminals, VmuCore.MBS.Terminal, foreign_key: :merchant_id

    timestamps()
  end

  @valid_types   ~w(CHAIN STANDALONE VIRTUAL)
  @valid_statuses ~w(ACTIVE SUSPENDED CLOSED)

  def changeset(merchant, attrs) do
    merchant
    |> cast(attrs, [:sys_id, :bank_id, :merchant_name, :merchant_type, :mcc,
                    :registration_no, :vat_no, :settlement_bank, :settlement_iban,
                    :mdr_template_id, :status])
    |> validate_required([:sys_id, :bank_id, :merchant_name, :merchant_type, :mcc])
    |> validate_inclusion(:merchant_type, @valid_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_length(:mcc, is: 4)
    |> validate_iban()
  end

  defp validate_iban(cs) do
    type = get_field(cs, :merchant_type)
    iban = get_field(cs, :settlement_iban)

    if type in ["CHAIN", "STANDALONE"] and is_nil(iban) do
      add_error(cs, :settlement_iban, "is required for #{type} merchants")
    else
      cs
    end
  end
end
