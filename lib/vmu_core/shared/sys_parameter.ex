defmodule VmuCore.Shared.SysParameter do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:sys_id, :string, []}
  schema "sys_parameters" do
    field :description, :string
    field :base_currency, :string, default: "AED"

    timestamps()
  end

  def changeset(sys_parameter, attrs) do
    sys_parameter
    |> cast(attrs, [:sys_id, :description, :base_currency])
    |> validate_required([:sys_id, :description])
    |> validate_length(:sys_id, is: 4)
    |> validate_length(:base_currency, is: 3)
  end
end
