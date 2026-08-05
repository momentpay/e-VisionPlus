defmodule VmuCore.Posting.JournalEntry do
  @moduledoc """
  The subledger — one row per product-account movement (WAY4's `GL_TRACE`).

  Where `PostingLeg` records what happened to a *GL account*, a journal entry
  records what happened to a *customer's product account*, naming the debited
  and credited GL accounts alongside it. That is the separation
  `cms_ledger_entries` currently conflates: it is simultaneously the
  subledger and the general ledger, which is why "what does this customer
  owe" and "what do the bank's books say" cannot be answered independently
  today.

  Journal entries carry `transaction_date`, `posting_date` and `gl_date` but
  **not** `banking_date` — the banking day is a property of the execution,
  not of a customer's account activity.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.Posting.{PostingEntry, PostingSet, Rule}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "journal_entries" do
    field :account_ref,   :string
    field :product,       :string
    field :dr_gl_account, :string
    field :cr_gl_account, :string
    field :amount,        :decimal
    field :currency,      :string

    field :transaction_date, :date
    field :posting_date,     :date
    field :gl_date,          :date

    field :narrative, :string

    belongs_to :posting_set,   PostingSet
    belongs_to :posting_entry, PostingEntry

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[posting_set_id posting_entry_id account_ref product
               dr_gl_account cr_gl_account amount currency posting_date gl_date]a
  @optional ~w[transaction_date narrative]a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_inclusion(:product, Rule.products())
    |> validate_number(:amount, greater_than: Decimal.new(0))
    |> validate_length(:currency, is: 3)
    |> validate_distinct_accounts()
    |> foreign_key_constraint(:posting_set_id)
    |> foreign_key_constraint(:posting_entry_id)
    |> foreign_key_constraint(:dr_gl_account)
    |> foreign_key_constraint(:cr_gl_account)
    |> check_constraint(:dr_gl_account, name: :journal_entries_distinct_accounts_check)
    |> check_constraint(:amount, name: :journal_entries_amount_positive_check)
  end

  defp validate_distinct_accounts(changeset) do
    dr = get_field(changeset, :dr_gl_account)
    cr = get_field(changeset, :cr_gl_account)

    if not is_nil(dr) and dr == cr do
      add_error(changeset, :cr_gl_account, "must differ from dr_gl_account")
    else
      changeset
    end
  end
end
