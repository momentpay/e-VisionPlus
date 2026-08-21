defmodule VmuCore.Posting.PostingEntry do
  @moduledoc """
  One balanced posting within a `PostingSet` (Koṣa DOC-109 §24).

  A simple double entry is one entry with two legs. A multi-leg execution —
  a purchase and its fee in one transaction — is two entries in one set, four
  legs total.

  `amount` is the entry's declared value. The database requires the legs to
  sum to it on both sides at COMMIT: see `posting_entry_must_balance()` in
  migration `20260802000006`. That check is deferred, so an entry may be
  legitimately unbalanced while it is being assembled inside a transaction.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias VmuCore.Posting.{PostingLeg, PostingSet}

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @type t :: %__MODULE__{}

  schema "posting_entries" do
    field :sequence,  :integer
    field :amount,    :decimal
    field :currency,  :string
    field :narrative, :string

    belongs_to :posting_set, PostingSet
    has_many :legs, PostingLeg, foreign_key: :posting_entry_id

    timestamps(type: :utc_datetime_usec)
  end

  @required ~w[posting_set_id sequence amount currency]a
  @optional ~w[narrative]a

  def changeset(entry, attrs) do
    entry
    |> cast(attrs, @required ++ @optional)
    |> validate_required(@required)
    |> validate_number(:amount, greater_than: Decimal.new(0))
    |> validate_number(:sequence, greater_than: 0)
    |> validate_length(:currency, is: 3)
    |> unique_constraint([:posting_set_id, :sequence])
    |> foreign_key_constraint(:posting_set_id)
    |> check_constraint(:amount, name: :posting_entries_amount_positive_check)
  end

  @doc """
  Builds the two legs of a standard double entry from a debit/credit account
  pair. The overwhelmingly common case, kept in one place so callers cannot
  get the direction the wrong way round.
  """
  @spec double_entry_legs(t(), {String.t(), String.t()}) :: [map()]
  def double_entry_legs(%__MODULE__{id: id, amount: amount, currency: currency}, {dr, cr}) do
    [
      %{posting_entry_id: id, direction: "debit",  gl_account: dr, amount: amount, currency: currency},
      %{posting_entry_id: id, direction: "credit", gl_account: cr, amount: amount, currency: currency}
    ]
  end
end
