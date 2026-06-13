defmodule VmuCore.CMS.StipThreshold do
  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false

  schema "stip_thresholds" do
    field :sys_id,             :string
    field :logo_id,            :string
    field :max_amount,         :decimal
    field :max_cumulative,     :decimal
    field :allowed_mcc_groups, {:array, :string}
    field :inserted_at,        :naive_datetime
  end

  def changeset(threshold, attrs) do
    threshold
    |> cast(attrs, [:sys_id, :logo_id, :max_amount, :max_cumulative, :allowed_mcc_groups])
    |> validate_required([:sys_id, :logo_id, :max_amount, :max_cumulative])
  end
end
