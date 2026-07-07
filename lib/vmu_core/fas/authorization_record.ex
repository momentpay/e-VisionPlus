defmodule VmuCore.FAS.AuthorizationRecord do
  @moduledoc "Ecto schema for the fas_authorizations table."

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "fas_authorizations" do
    field :pan_token,     :string
    field :account_id,    :binary_id
    field :logo_id,       :string
    field :sys_id,        :string
    field :amount,        :decimal
    field :currency,      :string
    field :mcc,           :string
    field :channel,       :string
    field :mti,           :string
    field :rc,            :string
    field :approval_code, :string
    field :stan,          :string
    field :rrn,           :string
    field :terminal_id,   :string
    field :merchant_id,   :string
    field :stip_used,     :boolean, default: false
    field :risk_score,    :float
    field :decision_path, :map, default: %{}

    timestamps(type: :utc_datetime_usec, updated_at: false)
  end

  @required ~w[pan_token amount currency channel mti rc]a
  @optional ~w[account_id logo_id sys_id mcc approval_code stan rrn
               terminal_id merchant_id stip_used risk_score decision_path]a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_length(:pan_token, is: 64)
    |> validate_length(:rc, is: 2)
    |> validate_length(:approval_code, is: 6, allow_nil: true)
  end
end
