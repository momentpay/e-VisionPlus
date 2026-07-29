defmodule VmuCore.Kyc.Request do
  @moduledoc """
  One KYC submission for one customer, for exactly one product
  (`docs/kyc/KYC_Implementation_Tracker.md` §3.3). `fields_snapshot` freezes
  the method's field definitions at submission time, so a later edit to the
  method template (which bumps its own `version`) never corrupts how a past
  submission renders.

  `status` reuses the richer state-machine shape proven in both the MMS
  reference and Avenza's `wallet_kyc` (`submitted -> under_review ->
  approved/rejected/expired`), not the reference's flat 0/1/2/3.

  `step` snapshots the method's `step` number at submission time (KYC-P3.5)
  — same reasoning as `fields_snapshot`/`method_version`: a later edit to the
  method's step ordering never reclassifies a past submission.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.CMS.Arrangement

  @primary_key {:request_id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @statuses ~w[submitted under_review approved rejected expired]

  schema "kyc_requests" do
    field :application_number, :string
    field :kyc_method_id, :binary_id
    field :method_version, :integer
    field :fields_snapshot, {:array, :map}, default: []
    field :customer_id, :binary_id
    field :product_type, :string
    field :step, :integer, default: 1
    field :arrangement_id, :binary_id
    field :data, :map, default: %{}
    field :status, :string, default: "submitted"
    field :reviewer_id, :binary_id
    field :decision_reason, :string
    field :submitted_at, :utc_datetime
    field :reviewed_at, :utc_datetime
    field :expires_at, :utc_datetime

    timestamps(type: :utc_datetime)
  end

  @required ~w[kyc_method_id method_version fields_snapshot customer_id product_type]a
  @optional ~w[application_number step arrangement_id data status reviewer_id
               decision_reason submitted_at reviewed_at expires_at]a

  @doc false
  def changeset(request, attrs) do
    request
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:product_type, Arrangement.product_types())
    |> validate_inclusion(:status, @statuses)
    |> unique_constraint(:application_number)
  end

  @doc "Statuses a request can be in."
  def statuses, do: @statuses
end
