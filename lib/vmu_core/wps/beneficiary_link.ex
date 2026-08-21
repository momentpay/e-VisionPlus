defmodule VmuCore.WPS.BeneficiaryLink do
  @moduledoc """
  Resolves an employer's own `employee_id` to a disbursement account (W1).

  This *is* the worker roster. There is no separate worker table, because a
  worker only matters to WPS once there is somewhere to pay them — and that is
  exactly what this records.

  ## Why the employee id is not unique on its own

  `employee_id` is the **employer's** key, not ours. Two employers may both
  number their staff from "001". The unique index is therefore on
  `(employer_id, employee_id)`, and every lookup must carry the employer.
  Getting this wrong would pay one company's worker from another company's file.

  ## Status

  | | |
  |---|---|
  | `UNVERIFIED` | recorded from a file; the account is not yet confirmed |
  | `ACTIVE` | resolvable, salary credits may post |
  | `SUSPENDED` | worker left, disputed, or KYC lapsed |

  `UNVERIFIED` exists because a salary file is the first time the bank hears
  about most of these workers. Refusing to record a line until an account
  exists would mean discarding the only evidence that the worker is owed
  anything — so the line is recorded, the link is created unverified, and the
  disbursement lands in the exception queue for remediation rather than being
  silently dropped.

  A database check constraint enforces that an `ACTIVE` link has an account.
  That invariant is what the entire disbursement path assumes, so it is not
  left to application code.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.WPS.Employer

  @primary_key {:link_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[UNVERIFIED ACTIVE SUSPENDED]

  schema "wps_beneficiary_links" do
    field :employee_id, :string
    field :employee_name, :string

    field :prepaid_account_id, :binary_id

    field :status, :string, default: "UNVERIFIED"
    field :linked_by, :string
    field :linked_at, :utc_datetime_usec
    field :suspended_reason, :string

    belongs_to :employer, Employer, foreign_key: :employer_id, references: :employer_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[employer_id employee_id]a
  @optional ~w[employee_name prepaid_account_id status linked_by linked_at suspended_reason]a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(link, attrs) do
    link
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_active_has_account()
    |> unique_constraint([:employer_id, :employee_id],
      name: :wps_beneficiary_links_employee_idx,
      message: "this employee is already linked for this employer"
    )
    |> foreign_key_constraint(:employer_id)
    |> check_constraint(:status, name: :wps_beneficiary_links_status_check)
    |> check_constraint(:prepaid_account_id,
      name: :wps_beneficiary_links_active_has_account_check,
      message: "an active link must have a disbursement account"
    )
  end

  # Mirrors the database constraint so the caller gets a field-level error
  # rather than a constraint violation surfaced from the driver.
  defp validate_active_has_account(changeset) do
    case {get_field(changeset, :status), get_field(changeset, :prepaid_account_id)} do
      {"ACTIVE", nil} ->
        add_error(changeset, :prepaid_account_id, "an active link must have a disbursement account")

      _ ->
        changeset
    end
  end

  @doc "Statuses a link may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  True when a salary credit may post against this link.

  `UNVERIFIED` is deliberately not payable: the line is kept, the disbursement
  is not attempted, and remediation happens through the exception queue.
  """
  @spec payable?(t()) :: boolean()
  def payable?(%__MODULE__{status: "ACTIVE", prepaid_account_id: id}) when not is_nil(id), do: true
  def payable?(%__MODULE__{}), do: false
end
