defmodule VmuCore.GL.PostingException do
  @moduledoc """
  A posting that could not be accepted onto the GL because its `gl_date`
  falls outside what is open (GL Phase A4; WAY4's "GL Trace Exceptions").

  WAY4's operating rule, adopted here: **in a healthy system this table is
  empty.** Rows mean processes ran in the wrong order — typically a close
  running before something that still needed to post to the day being closed.

  Quarantining is the right behaviour because both alternatives are worse:
  accepting the posting silently corrupts a closed period's reported figures,
  and rejecting it outright loses a real financial event.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.Posting.PostingSet

  @type t :: %__MODULE__{}

  @reasons ~w[
    GL_DATE_IN_CLOSED_PERIOD
    GL_DATE_BEFORE_CLOSE_POINT
    NO_OPEN_PERIOD
    BANKING_DATE_CLOSED
  ]

  schema "gl_posting_exceptions" do
    field :sys_id,  :string
    field :bank_id, :string

    field :attempted_gl_date, :date
    field :banking_date,      :date
    field :close_point,       :date

    field :reason,      :string
    field :detail,      :string
    field :resolved,    :boolean, default: false
    field :resolved_at, :utc_datetime_usec
    field :resolved_by, :string
    field :resolution,  :string

    belongs_to :posting_set, PostingSet, type: :binary_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[sys_id bank_id attempted_gl_date banking_date reason]a
  @optional ~w[posting_set_id close_point detail resolved resolved_at resolved_by resolution]a

  def changeset(exception, attrs) do
    exception
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:reason, @reasons)
    |> foreign_key_constraint(:posting_set_id)
    |> check_constraint(:reason, name: :gl_posting_exceptions_reason_check)
  end

  def reasons, do: @reasons
end
