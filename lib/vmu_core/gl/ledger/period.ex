defmodule VmuCore.GL.Period do
  @moduledoc """
  An accounting period for one institution (GL Phase A4, Koṣa DOC-110 §13).

  Lifecycle: `OPEN` → `CLOSED` → `LOCKED`.

  * **OPEN** — postings may land in it.
  * **CLOSED** — no new postings; may be reopened by an authorised operator.
  * **LOCKED** — permanent. Reopening is not possible, which is what makes a
    reported figure defensible after the fact.

  Periods for one institution may not overlap. That is enforced by a GiST
  exclusion constraint in the database rather than in application code,
  because concurrent period creation would otherwise race.

  Until this existed the platform had **no period close at all** — every
  posting date was equally writable forever, which is the audit exposure
  recorded in the Koṣa handbook alignment assessment.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  @statuses ~w[OPEN CLOSED LOCKED]

  schema "gl_periods" do
    field :sys_id,  :string
    field :bank_id, :string

    field :period_start, :date
    field :period_end,   :date
    field :status,       :string, default: "OPEN"

    field :closed_at, :utc_datetime_usec
    field :closed_by, :string
    field :locked_at, :utc_datetime_usec

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[sys_id bank_id period_start period_end]a
  @optional ~w[status closed_at closed_by locked_at]a

  def changeset(period, attrs) do
    period
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_range()
    |> unique_constraint([:sys_id, :bank_id, :period_start])
    |> exclusion_constraint(:period_start,
         name: :gl_periods_no_overlap,
         message: "overlaps an existing period for this institution")
    |> check_constraint(:period_end, name: :gl_periods_range_check)
  end

  @doc "True when `date` falls inside this period, inclusive of both ends."
  @spec covers?(t(), Date.t()) :: boolean()
  def covers?(%__MODULE__{period_start: s, period_end: e}, date) do
    Date.compare(date, s) != :lt and Date.compare(date, e) != :gt
  end

  @doc "True when postings may still land in this period."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: "OPEN"}), do: true
  def open?(%__MODULE__{}), do: false

  def statuses, do: @statuses

  defp validate_range(changeset) do
    with s when not is_nil(s) <- get_field(changeset, :period_start),
         e when not is_nil(e) <- get_field(changeset, :period_end),
         :gt <- Date.compare(s, e) do
      add_error(changeset, :period_end, "must not be before period_start")
    else
      _ -> changeset
    end
  end
end
