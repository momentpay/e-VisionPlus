defmodule VmuCore.GL.LedgerEntry do
  @moduledoc """
  A consolidated general-ledger entry (GL Phase A4/A5; WAY4's `GL_TRANSFER`).

  One row per
  `{sys_id, bank_id, gl_date, dr_account, cr_account, currency, generation}`.
  Journal entries accumulate into it: this is the **bank's books** view, where
  `Posting.JournalEntry` is the **customer's account** view. Today
  `cms_ledger_entries` conflates the two, which is why neither question can be
  answered independently.

  ## Lifecycle

  `OPEN` → `EXTRACTED` → `CLOSED`, following WAY4:

    * **OPEN** — still accumulating for that date and correspondence.
    * **EXTRACTED** — closed manually so current figures can be reported
      before export.
    * **CLOSED** — exported; turnover applied to the account.

  ## `generation`

  WAY4's rule: once an entry is closed, further activity for the same account
  correspondence on the same date opens a **second** entry rather than
  reopening the first. Without it, closing would either be a lie or would have
  to reject late activity outright — and late activity is normal, not
  exceptional.

  Note the distinction from `GL.PostingException`: a *later generation* is the
  answer to activity arriving after a **GL entry** closed, whereas the
  exception table is for activity arriving after the **period** closed. The
  first is routine; the second is a control failure.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.GL.Period

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  @statuses ~w[OPEN EXTRACTED CLOSED]

  schema "gl_ledger_entries" do
    field :sys_id,  :string
    field :bank_id, :string

    field :gl_date,    :date
    field :dr_account, :string
    field :cr_account, :string
    field :currency,   :string

    field :amount,      :decimal, default: Decimal.new(0)
    field :entry_count, :integer, default: 0
    field :generation,  :integer, default: 1

    field :status,       :string, default: "OPEN"
    field :extracted_at, :utc_datetime_usec
    field :closed_at,    :utc_datetime_usec

    belongs_to :period, Period, type: :id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[sys_id bank_id gl_date dr_account cr_account currency amount]a
  @optional ~w[entry_count generation status extracted_at closed_at period_id]a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:status, @statuses)
    |> validate_number(:amount, greater_than_or_equal_to: Decimal.new(0))
    |> validate_number(:generation, greater_than: 0)
    |> validate_length(:currency, is: 3)
    |> validate_distinct_accounts()
    |> unique_constraint(
      [:sys_id, :bank_id, :gl_date, :dr_account, :cr_account, :currency, :generation],
      name: :gl_ledger_entries_correspondence_idx
    )
    |> foreign_key_constraint(:dr_account)
    |> foreign_key_constraint(:cr_account)
    |> check_constraint(:status, name: :gl_ledger_entries_status_check)
    |> check_constraint(:amount, name: :gl_ledger_entries_amount_non_negative_check)
  end

  @doc "True when this entry may still accumulate activity."
  @spec open?(t()) :: boolean()
  def open?(%__MODULE__{status: "OPEN"}), do: true
  def open?(%__MODULE__{}), do: false

  def statuses, do: @statuses

  defp validate_distinct_accounts(changeset) do
    dr = get_field(changeset, :dr_account)
    cr = get_field(changeset, :cr_account)

    if not is_nil(dr) and dr == cr do
      add_error(changeset, :cr_account, "must differ from dr_account")
    else
      changeset
    end
  end
end
