defmodule VmuCore.Shared.LogoParameter do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  schema "logo_parameters" do
    field :logo_id, :string, primary_key: true
    field :sys_id, :string, primary_key: true
    field :bank_id, :string, primary_key: true
    field :bin_prefix, :string
    field :description, :string

    timestamps()
  end

  def changeset(logo_parameter, attrs) do
    logo_parameter
    |> cast(attrs, [:logo_id, :sys_id, :bank_id, :bin_prefix, :description])
    |> validate_required([:logo_id, :sys_id, :bank_id, :bin_prefix, :description])
    |> validate_length(:logo_id, is: 4)
    |> validate_length(:sys_id, is: 4)
    |> validate_length(:bank_id, is: 4)
    |> validate_length(:bin_prefix, is: 6)
  end
end
