defmodule VmuCore.WPS.SalaryCredit do
  @moduledoc """
  One line of a salary file: one worker, one pay period, one amount (W2).

  ## Status

  | | |
  |---|---|
  | `PARSED` | read from the file |
  | `VALIDATED` | passed line validation and resolved to an account |
  | `POSTED` | disbursed |
  | `FAILED` | could not be disbursed; an exception row explains why |

  Transitions are guarded by `mark_*` rather than by letting a caller set
  `status` freely. The one that matters is `POSTED`: money has moved, and a
  status machine that allows moving back out of it invites a re-run to pay the
  worker twice.

  ## `payment_reference`

  The employer's own reference for this payment, and the basis of the
  disbursement idempotency key. Unique per employer at the database level — a
  re-run, or a corrected file that repeats a reference, must not pay twice.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.WPS.{Employer, WpsFile}

  @primary_key {:salary_credit_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[PARSED VALIDATED POSTED FAILED]

  schema "wps_salary_credits" do
    field :line_number, :integer

    field :employee_id, :string
    field :employee_name, :string
    field :payment_reference, :string

    field :gross_amount, :decimal
    field :deduction_amount, :decimal
    field :net_amount, :decimal
    field :currency, :string, default: "AED"

    field :pay_period_start, :date
    field :pay_period_end, :date
    field :payment_date, :date

    field :prepaid_account_id, :binary_id

    field :status, :string, default: "PARSED"
    field :failure_reason, :string
    field :posted_at, :utc_datetime_usec

    belongs_to :wps_file, WpsFile, foreign_key: :wps_file_id, references: :wps_file_id
    belongs_to :employer, Employer, foreign_key: :employer_id, references: :employer_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[wps_file_id employer_id line_number employee_id payment_reference net_amount]a
  @optional ~w[employee_name gross_amount deduction_amount currency pay_period_start
               pay_period_end payment_date prepaid_account_id status failure_reason posted_at]a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(credit, attrs) do
    credit
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:net_amount, greater_than: Decimal.new(0))
    # Matches the column. Without it an over-long reason raises a Postgrex
    # error from inside a transaction rather than returning a changeset error —
    # which is how a single unpayable line took down a whole batch until it was
    # caught here (2026-08-06).
    |> validate_length(:failure_reason, max: 300)
    |> unique_constraint([:employer_id, :payment_reference],
      name: :wps_salary_credits_payment_ref_idx,
      message: "this payment reference has already been recorded for this employer"
    )
    |> check_constraint(:net_amount, name: :wps_salary_credits_net_positive_check)
    |> check_constraint(:status, name: :wps_salary_credits_status_check)
  end

  @doc "Statuses a salary credit may hold."
  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc """
  Marks a credit validated against a resolved account.

  Only from `PARSED` or `FAILED` — the second so a remediated exception can be
  retried, which is the whole point of the exception queue.
  """
  @spec mark_validated(t(), Ecto.UUID.t()) :: Ecto.Changeset.t() | {:error, :invalid_transition}
  def mark_validated(%__MODULE__{status: s} = credit, account_id) when s in ["PARSED", "FAILED"] do
    changeset(credit, %{status: "VALIDATED", prepaid_account_id: account_id, failure_reason: nil})
  end

  def mark_validated(%__MODULE__{}, _account_id), do: {:error, :invalid_transition}

  @doc """
  Marks a credit posted. Terminal — there is no transition out.

  Money has moved. A status machine that allowed leaving `POSTED` would let a
  re-run pay the worker again; reversing a disbursement is an employer refund
  (W4), which is a new posting, not a status change.
  """
  @spec mark_posted(t()) :: Ecto.Changeset.t() | {:error, :invalid_transition}
  def mark_posted(%__MODULE__{status: "VALIDATED"} = credit) do
    changeset(credit, %{status: "POSTED", posted_at: DateTime.utc_now()})
  end

  def mark_posted(%__MODULE__{}), do: {:error, :invalid_transition}

  @doc "Marks a credit failed, with the reason an operator will act on."
  @spec mark_failed(t(), String.t()) :: Ecto.Changeset.t() | {:error, :invalid_transition}
  def mark_failed(%__MODULE__{status: "POSTED"}), do: {:error, :invalid_transition}

  def mark_failed(%__MODULE__{} = credit, reason) do
    changeset(credit, %{status: "FAILED", failure_reason: String.slice(to_string(reason), 0, 300)})
  end

  def mark_failed(%__MODULE__{status: "POSTED"}, _reason), do: {:error, :invalid_transition}
end
