defmodule VmuCore.DPS.ReasonCode do
  @moduledoc """
  Reference-data schema for network dispute reason codes (FR-DPS-004).

  Per `docs/tram/08_chargebacks_disputes.md` §4: reason codes and their dispute
  windows differ by network and change periodically via network rule updates —
  modeled as admin-editable reference data, not a hardcoded enum, so updates never
  require a code deployment.

  `network` uses the same short codes as `VmuCore.DPS.Dispute.network` (`"VI"`,
  `"MC"`, ...), not the `network_connectivity_mode` config's full names.

  Seeded illustrative defaults (`priv/repo/seed_dps_reason_codes.exs`) — validate
  against current Visa/Mastercard operating regulations before go-live; this is
  reference data precisely so that validation is a data update, not a code change.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias VmuCore.Repo

  @primary_key {:id, :binary_id, autogenerate: true}

  schema "dps_reason_codes" do
    field :network,             :string
    field :reason_code,         :string
    field :description,         :string
    field :category,            :string
    field :dispute_window_days, :integer
    field :evidence_required,   {:array, :string}, default: []

    timestamps()
  end

  def changeset(reason_code, attrs) do
    reason_code
    |> cast(attrs, [:network, :reason_code, :description, :category,
                    :dispute_window_days, :evidence_required])
    |> validate_required([:network, :reason_code, :description, :dispute_window_days])
    |> validate_number(:dispute_window_days, greater_than: 0)
    |> unique_constraint([:network, :reason_code])
  end

  @doc "Look up a reason code's reference row for a network. Returns `nil` if not found."
  @spec get(String.t(), String.t()) :: %__MODULE__{} | nil
  def get(network, code) do
    Repo.one(from r in __MODULE__, where: r.network == ^network and r.reason_code == ^code)
  end

  @doc """
  Dispute window (days) for a network/reason code, falling back to `default_days`
  (the historical static value) when the code isn't in the reference table.
  """
  @spec window_days(String.t(), String.t(), integer()) :: integer()
  def window_days(network, code, default_days) do
    case get(network, code) do
      %__MODULE__{dispute_window_days: days} -> days
      nil -> default_days
    end
  end
end
