defmodule VmuCore.WPS.Employer do
  @moduledoc """
  An organisation that pays wages through the Wage Protection System (W1).

  ## Not an `HCS.Company`

  They share a shape — one organisation, many workers, funded centrally — but
  not a meaning. An HCS company is a **credit** customer: it holds a facility,
  its employees spend against the company's limit, and the company owes the
  bank. A WPS employer is a **disbursement counterparty**: it pushes its own
  money out to workers who are the bank's customers, and owes the bank nothing.

  Reusing `HCS.Company` would have meant carrying a `credit_limit` that is never
  consulted and a `liability_model` that does not apply.

  ## `regulator_id`

  Deliberately generic. The UAE issues a MOHRE establishment ID; Saudi and
  Bahrain use their own schemes; an exchange house intermediating for several
  markets sees all of them. Naming the column `mohre_id` would have hard-coded
  one market into the schema of a product the requirements explicitly say must
  be "open as per market".
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:employer_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[ACTIVE SUSPENDED CLOSED]

  schema "wps_employers" do
    field :sys_id, :string
    field :bank_id, :string

    field :employer_code, :string
    field :employer_name, :string

    field :regulator_id, :string
    field :jurisdiction, :string

    field :funding_account_id, :binary_id

    field :status, :string, default: "ACTIVE"
    field :onboarded_at, :utc_datetime_usec
    field :notes, :string

    has_many :beneficiary_links, VmuCore.WPS.BeneficiaryLink, foreign_key: :employer_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[sys_id bank_id employer_code employer_name]a
  @optional ~w[regulator_id jurisdiction funding_account_id status onboarded_at notes]a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(employer, attrs) do
    employer
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_length(:sys_id, max: 4)
    |> validate_length(:bank_id, max: 4)
    |> unique_constraint([:sys_id, :bank_id, :employer_code],
      name: :wps_employers_code_idx,
      message: "an employer with this code already exists for this institution"
    )
    |> unique_constraint([:sys_id, :bank_id, :regulator_id],
      name: :wps_employers_regulator_idx,
      message: "this regulator id is already registered to another employer"
    )
    |> check_constraint(:status, name: :wps_employers_status_check)
  end

  @doc "Statuses an employer may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  True when this employer may have salary credits posted for it.

  A SUSPENDED employer keeps its roster and its history — suspension stops
  money moving, it does not unwind what already moved.
  """
  @spec disbursable?(t()) :: boolean()
  def disbursable?(%__MODULE__{status: "ACTIVE"}), do: true
  def disbursable?(%__MODULE__{}), do: false
end
