defmodule VmuCore.HCS.SpendingControl do
  use Ecto.Schema
  import Ecto.Changeset

  schema "hcs_spending_controls" do
    field :scope,            :string        # COMPANY | EMPLOYEE
    field :company_id,       :integer
    field :employee_card_id, :integer
    field :control_type,     :string
    field :mcc_codes,        {:array, :string}, default: []
    field :channels,         {:array, :string}, default: []
    field :daily_cap,        :decimal
    field :per_txn_cap,      :decimal
    field :effective_from,   :date
    field :effective_to,     :date
    field :status,           :string, default: "ACTIVE"
    field :inserted_at,      :utc_datetime
  end

  @valid_scopes        ~w(COMPANY EMPLOYEE)
  @valid_control_types ~w(MCC_BLOCK MCC_ALLOW CHANNEL_BLOCK DAILY_CAP TXN_CAP)
  @valid_statuses      ~w(ACTIVE INACTIVE)

  def changeset(control, attrs) do
    control
    |> cast(attrs, [:scope, :company_id, :employee_card_id, :control_type, :mcc_codes,
                    :channels, :daily_cap, :per_txn_cap, :effective_from, :effective_to,
                    :status, :inserted_at])
    |> validate_required([:scope, :company_id, :control_type, :effective_from])
    |> validate_inclusion(:scope, @valid_scopes)
    |> validate_inclusion(:control_type, @valid_control_types)
    |> validate_inclusion(:status, @valid_statuses)
    |> validate_employee_scope()
  end

  defp validate_employee_scope(cs) do
    case get_field(cs, :scope) do
      "EMPLOYEE" -> validate_required(cs, [:employee_card_id])
      _          -> cs
    end
  end
end
