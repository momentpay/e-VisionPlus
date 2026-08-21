defmodule VmuCore.WPS.SalaryCreditException do
  @moduledoc """
  A salary credit that could not be disbursed (W3).

  ## Why failures get a record rather than a log line

  A WPS batch is a regulated payment instruction. A worker who was not paid is a
  compliance event, and "it failed and nobody noticed" is the outcome this
  exists to prevent. The requirements put it directly: failed disbursements
  *"need a real remediation workflow, not silent drops"*.

  ## Classification drives the queue

  An operator fixes every `BENEFICIARY_UNRESOLVED` line one way — link the
  worker — and every `ACCOUNT_INACTIVE` line another. Grouping by cause is what
  makes a queue workable at the scale a payroll batch produces; a flat list of
  four hundred failures is not.

  | | |
  |---|---|
  | `BENEFICIARY_UNRESOLVED` | no roster link for this employee |
  | `BENEFICIARY_NOT_ACTIVE` | link exists but is unverified or suspended |
  | `ACCOUNT_INACTIVE` | the prepaid account is closed or blocked |
  | `POSTING_FAILED` | the ledger or GL refused the posting |
  | `VALIDATION_FAILED` | the line itself is not payable |
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.WPS.{Employer, SalaryCredit}

  @primary_key {:exception_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[OPEN RESOLVED ABANDONED]
  @types ~w[BENEFICIARY_UNRESOLVED BENEFICIARY_NOT_ACTIVE ACCOUNT_INACTIVE
            POSTING_FAILED VALIDATION_FAILED]

  schema "wps_salary_credit_exceptions" do
    field :exception_type, :string
    field :reason, :string
    field :status, :string, default: "OPEN"

    field :attempt_count, :integer, default: 1
    field :last_attempted_at, :utc_datetime_usec

    field :resolved_at, :utc_datetime_usec
    field :resolved_by, :string
    field :resolution_note, :string

    belongs_to :salary_credit, SalaryCredit,
      foreign_key: :salary_credit_id,
      references: :salary_credit_id

    belongs_to :employer, Employer, foreign_key: :employer_id, references: :employer_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[salary_credit_id employer_id exception_type reason]a
  @optional ~w[status attempt_count last_attempted_at resolved_at resolved_by resolution_note]a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(exception, attrs) do
    exception
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:exception_type, @types)
    |> unique_constraint(:salary_credit_id,
      name: :wps_salary_credit_exceptions_one_open_idx,
      message: "this credit already has an open exception"
    )
    |> check_constraint(:status, name: :wps_salary_credit_exceptions_status_check)
    |> check_constraint(:exception_type, name: :wps_salary_credit_exceptions_type_check)
  end

  @doc "Exception statuses."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "Exception classifications."
  @spec types() :: [String.t()]
  def types, do: @types

  @doc """
  Classifies a disbursement failure.

  Reasons the roster and the account give back are mapped to the operator-facing
  categories, so the queue groups by *what to do about it* rather than by which
  function happened to return the error.
  """
  @spec classify(term()) :: String.t()
  def classify(:not_linked), do: "BENEFICIARY_UNRESOLVED"
  def classify({:not_payable, _status}), do: "BENEFICIARY_NOT_ACTIVE"
  def classify(:prepaid_account_not_active), do: "ACCOUNT_INACTIVE"
  def classify(:not_active), do: "ACCOUNT_INACTIVE"
  def classify(:not_found), do: "ACCOUNT_INACTIVE"
  def classify(:employer_not_disbursable), do: "VALIDATION_FAILED"
  def classify(:invalid_amount), do: "VALIDATION_FAILED"
  def classify(_other), do: "POSTING_FAILED"

  @doc "A human-readable reason, truncated to what the column holds."
  @spec describe(term()) :: String.t()
  def describe(reason) when is_binary(reason), do: String.slice(reason, 0, 500)

  def describe({:not_payable, status}),
    do: "the roster link for this employee is #{status}, not ACTIVE"

  def describe(:not_linked),
    do: "no roster link — this employee has not been matched to an account"

  def describe(:prepaid_account_not_active),
    do: "the prepaid account is not active"

  def describe(reason), do: reason |> inspect() |> String.slice(0, 500)
end
