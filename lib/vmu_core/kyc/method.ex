defmodule VmuCore.Kyc.Method do
  @moduledoc """
  A KYC form *template*, scoped to exactly one product (`docs/kyc/KYC_Implementation_Tracker.md`
  §3.1). `product_type` is validated against `VmuCore.CMS.Arrangement.product_types/0`
  — the same live cross-product taxonomy every other product already registers
  into, not a free-text field (the mistake found in Avenza's `wallet_kyc`).

  `fields` is a JSON array of field defs (see `VmuCore.Kyc.FieldTypes`) — the
  form is entirely runtime-editable through the admin builder UI, no deploy
  needed to add a new KYC step or change what it asks for.

  `step` + `required` (KYC-P3.5, confirmed with the user 2026-07-29) turn a
  product's KYC into an ordered, sequentially-gated journey — several methods
  can share one `product_type` at different `step` numbers (e.g. DEBIT step 1
  = Business Profile, step 2 = ID Verification, step 3 = Bank Details).
  `required: false` marks a step skippable when gating checks whether earlier
  steps are done (mirrors the MMS reference's `StepBypassConfig`, folded onto
  the method row here instead of a separate global table, since each method
  is already product+step scoped). Gating itself lives in `VmuCore.Kyc.
  Journey`, not here — this schema only carries the ordering data.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.CMS.Arrangement

  @primary_key {:method_id, :binary_id, autogenerate: true}

  @type t :: %__MODULE__{}

  @statuses ~w[active inactive]

  schema "kyc_methods" do
    field :name, :string
    field :title, :string
    field :product_type, :string
    field :status, :string, default: "active"
    field :version, :integer, default: 1
    field :fields, {:array, :map}, default: []
    field :conditional_rules, {:array, :map}
    field :cloned_from_method_id, :binary_id
    field :sys_id, :string
    field :bank_id, :string
    field :step, :integer, default: 1
    field :required, :boolean, default: true

    timestamps(type: :utc_datetime)
  end

  @required ~w[name title product_type]a
  @optional ~w[status fields conditional_rules cloned_from_method_id sys_id bank_id step required]a

  @doc false
  def changeset(method, attrs) do
    method
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:product_type, Arrangement.product_types())
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:step, greater_than_or_equal_to: 1)
    |> validate_fields()
  end

  @doc "Statuses a method can be in."
  def statuses, do: @statuses

  # ---------------------------------------------------------------------------
  # Private
  # ---------------------------------------------------------------------------

  defp validate_fields(changeset) do
    validate_change(changeset, :fields, fn :fields, fields ->
      fields
      |> Enum.with_index()
      |> Enum.flat_map(fn {field, idx} -> field_errors(field, idx) end)
    end)
  end

  defp field_errors(field, idx) do
    key = Map.get(field, "key") || Map.get(field, :key)
    label = Map.get(field, "label") || Map.get(field, :label)
    type = Map.get(field, "type") || Map.get(field, :type)

    cond do
      blank?(key) -> [fields: "field ##{idx + 1}: key is required"]
      blank?(label) -> [fields: "field ##{idx + 1} (#{key}): label is required"]
      blank?(type) -> [fields: "field ##{idx + 1} (#{key}): type is required"]
      not VmuCore.Kyc.FieldTypes.valid?(type) ->
        [fields: "field ##{idx + 1} (#{key}): unknown type #{inspect(type)}"]
      true -> []
    end
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
