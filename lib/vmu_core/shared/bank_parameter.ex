defmodule VmuCore.Shared.BankParameter do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "bank_parameters" do
    field :bank_id, :string, primary_key: true
    field :sys_id, :string, primary_key: true
    field :description, :string
    field :country_code, :string, default: "ARE"

    timestamps()
  end

  def changeset(bank_parameter, attrs) do
    bank_parameter
    |> cast(attrs, [:bank_id, :sys_id, :description, :country_code])
    |> validate_required([:bank_id, :sys_id, :description])
    |> validate_length(:bank_id, is: 4)
    |> validate_length(:sys_id, is: 4)
    |> validate_length(:country_code, is: 3)
  end
end
