defmodule VmuCore.GL.BankingDate do
  @moduledoc """
  The current banking day for one institution (GL Phase A4; WAY4's banking
  date, set by Start of Day).

  Per SYS/BANK rather than global, because EOD already runs per institution.

  Kept out of `bank_parameters` deliberately: this is operational state that
  moves every night, and `bank_parameters` exists to hold configuration that
  does not.

  ## Why `last_closed_date` matters

  It is WAY4's `CLOSE_GL` consistency point. A posting whose `gl_date` falls
  on or before it is arriving after the books for that day were closed —
  which is an exception to quarantine, not a posting to accept. See
  `VmuCore.GL.Periods.validate_gl_date/4`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @primary_key false
  @statuses ~w[OPEN CLOSING CLOSED]

  schema "gl_banking_dates" do
    field :sys_id,  :string, primary_key: true
    field :bank_id, :string, primary_key: true

    field :current_banking_date, :date
    field :status,               :string, default: "OPEN"
    field :last_closed_date,     :date
    field :opened_at,            :utc_datetime_usec
    field :closed_at,            :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[sys_id bank_id current_banking_date]a
  @optional ~w[status last_closed_date opened_at closed_at]a

  def changeset(banking_date, attrs) do
    banking_date
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> check_constraint(:status, name: :gl_banking_dates_status_check)
  end

  @doc "True when the institution's books are open for posting."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: "OPEN"}), do: true
  def open?(%__MODULE__{}), do: false

  def statuses, do: @statuses
end
