defmodule VmuCore.CMS.PrepaidNonMonetaryEvent do
  @moduledoc """
  Non-monetary Prepaid account maintenance events — Card Products UX
  Parity Phase 2d (2026-07-28), mirrors `CMS.DebitNonMonetaryEvent`
  exactly (own table, own FK). Same smaller event-type set as Debit's:
  no `cycle_change` (no billing cycle), no `card_reissue`, no
  `pin_change`.

  ## Supported Event Types

  | Type             | Description                          |
  |------------------|---------------------------------------|
  | `address_change` | Mailing or billing address updated    |
  | `phone_change`   | Contact phone number updated          |
  | `email_change`   | Contact email address updated         |
  | `name_change`    | Emboss name update                    |
  | `limit_change`   | Velocity/transaction limit change     |
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @valid_event_types ~w[address_change phone_change email_change name_change limit_change]
  @valid_operator_roles ~w[AGENT SUPERVISOR SYSTEM]

  schema "cms_prepaid_non_monetary_events" do
    field :prepaid_account_id, :binary_id
    field :event_type,         :string
    field :old_value,          :map
    field :new_value,          :map
    field :reason,             :string
    field :reference_id,       :string
    field :operator_id,        :binary_id
    field :operator_role,      :string, default: "AGENT"
    field :applied_at,         :naive_datetime

    timestamps(updated_at: false)
  end

  @type t :: %__MODULE__{}

  @required [:prepaid_account_id, :event_type, :operator_id, :applied_at]
  @optional [:old_value, :new_value, :reason, :reference_id, :operator_role]

  def changeset(event, attrs) do
    event
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:event_type, @valid_event_types)
    |> validate_inclusion(:operator_role, @valid_operator_roles)
    |> validate_length(:reason, max: 255)
    |> validate_length(:reference_id, max: 50)
  end

  @spec record(keyword()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def record(opts) do
    attrs =
      opts
      |> Map.new()
      |> Map.put_new(:applied_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    %__MODULE__{}
    |> changeset(attrs)
    |> Repo.insert()
  end

  @spec history_for(binary()) :: [t()]
  def history_for(prepaid_account_id) do
    Repo.all(
      from e in __MODULE__,
        where: e.prepaid_account_id == ^prepaid_account_id,
        order_by: [desc: e.applied_at]
    )
  end

  def valid_event_types, do: @valid_event_types
end
