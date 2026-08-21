defmodule VmuCore.WPS.RefundRequest do
  @moduledoc """
  An employer's request to recover a salary credit, under maker-checker (W4).

  ## Status

  | | |
  |---|---|
  | `PENDING` | awaiting a decision |
  | `APPROVED` | decided, and the money moved |
  | `REJECTED` | decided against |
  | `FAILED` | approved, but the money could not be recovered |

  `FAILED` is separate from `REJECTED` on purpose. A rejection is a judgement —
  someone looked and said no. A failure is the world refusing: the worker had
  already spent the wages. Collapsing them would lose the distinction between
  "we decided not to" and "we could not", which is exactly what an employer
  chasing an overpayment needs to be told apart.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.WPS.{Employer, SalaryCredit}

  @primary_key {:refund_request_id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[PENDING APPROVED REJECTED FAILED]

  schema "wps_refund_requests" do
    field :amount, :decimal
    field :reason, :string
    field :status, :string, default: "PENDING"

    field :requested_by, :string
    field :requested_at, :utc_datetime_usec

    field :decided_by, :string
    field :decided_at, :utc_datetime_usec
    field :decision_note, :string

    field :failure_reason, :string

    belongs_to :salary_credit, SalaryCredit,
      foreign_key: :salary_credit_id,
      references: :salary_credit_id

    belongs_to :employer, Employer, foreign_key: :employer_id, references: :employer_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[salary_credit_id employer_id amount reason requested_by requested_at]a
  @optional ~w[status decided_by decided_at decision_note failure_reason]a

  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(request, attrs) do
    request
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount, greater_than: Decimal.new(0))
    |> validate_length(:reason, min: 5, max: 500)
    |> validate_length(:failure_reason, max: 300)
    |> validate_maker_is_not_checker()
    |> unique_constraint(:salary_credit_id,
      name: :wps_refund_requests_one_pending_idx,
      message: "a refund request is already pending for this payment"
    )
    |> check_constraint(:status, name: :wps_refund_requests_status_check)
    |> check_constraint(:amount, name: :wps_refund_requests_amount_positive_check)
  end

  # The whole point of the control. Enforced on the record rather than only in
  # the calling function, so it holds however the row is written.
  defp validate_maker_is_not_checker(changeset) do
    maker = get_field(changeset, :requested_by)
    checker = get_field(changeset, :decided_by)

    if not is_nil(checker) and checker == maker do
      add_error(
        changeset,
        :decided_by,
        "the same person cannot both request and decide a refund"
      )
    else
      changeset
    end
  end

  @spec statuses() :: [String.t()]
  def statuses, do: @statuses

  @doc "True when this request is still awaiting a decision."
  @spec pending?(t()) :: boolean()
  def pending?(%__MODULE__{status: "PENDING"}), do: true
  def pending?(%__MODULE__{}), do: false
end
