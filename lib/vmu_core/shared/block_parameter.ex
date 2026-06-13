defmodule VmuCore.Shared.BlockParameter do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "block_parameters" do
    field :block_id, :string, primary_key: true
    field :sys_id, :string, primary_key: true
    field :bank_id, :string, primary_key: true
    field :logo_id, :string, primary_key: true
    field :apr_percentage, :decimal
    field :cash_advance_fee_percent, :decimal
    field :credit_limit_default, :decimal

    timestamps()
  end

  def changeset(block_parameter, attrs) do
    block_parameter
    |> cast(attrs, [
      :block_id, :sys_id, :bank_id, :logo_id,
      :apr_percentage, :cash_advance_fee_percent, :credit_limit_default
    ])
    |> validate_required([:block_id, :sys_id, :bank_id, :logo_id])
    |> validate_length(:block_id, is: 4)
    |> validate_length(:sys_id, is: 4)
    |> validate_length(:bank_id, is: 4)
    |> validate_length(:logo_id, is: 4)
    |> validate_number(:apr_percentage, greater_than_or_equal_to: 0)
    |> validate_number(:cash_advance_fee_percent, greater_than_or_equal_to: 0)
    |> validate_number(:credit_limit_default, greater_than_or_equal_to: 0)
  end
end
